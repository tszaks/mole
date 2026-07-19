# WORKLOG

记录 2026-07 这一轮架构 / 安全 / 性能审计后实际落地的改动，以及每条改动背后的判断。
这是历史维护记录，不代表当前 worktree 状态；实时事实以代码、测试、Git 与远端 CI 为准。

## 一、安全

### 1. 所有 `du` 目录测量都套上超时（含新增护栏测试）

`du -s` 对一棵大树或一个卡死的网络挂载点没有任何内部时限，而调用方普遍是
`size=$(du -skP "$path")` 这种命令替换，会一直等下去，整个扫描就此挂住。

原来只有一部分调用点走了 `run_with_timeout`。这次把剩下的全部补齐：

- `lib/core/file_ops.sh`：`get_path_size_kb` 主测量 + 3 处 sudo 测量
- `lib/clean/app_caches.sh`、`lib/clean/dev.sh`（2 处）、`lib/clean/apps.sh`（2 处）、
  `lib/optimize/tasks.sh`、`lib/uninstall/batch.sh`

统一用 `MOLE_TIMEOUT_DISK_VERIFY_SEC`（默认 30s，可用环境变量覆盖）。

护栏：`tests/core_timeout.bats` 新增一条源码不变量测试，grep 全仓 `lib/` `bin/` 里
每一处 `du -s`，只要有一处不在 `run_with_timeout` 行上就失败。以后再加测量点也不会漏。
另外 `tests/file_ops_mole_delete.bats` 加了一条真实行为测试：PATH 里塞一个 sleep 30s 的
假 du，`MOLE_TIMEOUT_DISK_VERIFY_SEC=1`，断言返回 0 且 10s 内结束。

### 2. `install.sh` 校验失败改为 fail-closed

原来 SHA256 校验不通过时，安装脚本会**降级去源码构建**。这等于把"二进制被篡改"这个
最该停下来的信号，变成了一条静默的备用路径：攻击者只要让校验失败，就能把你推到一条
校验更弱的链路上。

现在校验失败直接中止并说明原因，同时提示想装 main 分支源码版可以显式
`MOLE_VERSION=main ./install.sh`。另外，解析不到 latest tag 而回落 main 时，
现在会明确打一条 warning，不再静默装上 nightly。

`tests/install_checksum.bats` 三条用例改成断言"中止且没有触发源码构建"。

### 3. 删除路径校验补上祖先 symlink 检查

`validate_path_for_deletion` 只对传入路径本身做策略判断。如果路径的**父目录**是一个
指向 `/System` 之类的软链，字面路径看着人畜无害，实际落点是关键目录。

现在在策略判断前解析父目录真身（`cd -P`），如果解析后和原路径不同，就用解析后的路径
再跑一遍关键路径判断和 `should_protect_path`。这是 deny-only 的：只会多拒，不会多允。

护栏：`tests/core_safe_functions.bats` 三条（软链进 /System、软链进受保护用户数据、
普通路径仍然放行），`tests/path_validation_fuzz.bats` 一条属性测试，遍历
`/System /usr /bin /etc` 四个根。**注意故意不含 `/var`**：`/var/folders` 下的临时树本来
就是可清理的，字面路径都放行，软链形式也必须一致放行，不然就是自相矛盾。

### 4. `app_protection.sh` 里 `defaults read` 换成 `plutil -extract`

读第三方 app 的 Info.plist 用 `defaults read` 会走 cfprefsd，有缓存和副作用；
`plutil -extract ... raw` 是纯读文件。换掉 3 处（CFBundleExecutable / CFBundleIdentifier）。

## 二、架构

### 5. `mole` 派发器从 1184 行瘦到 316 行

自更新和自卸载两大块业务逻辑本来整个塞在派发器里。抽到 `lib/manage/update.sh`（652 行）
和 `lib/manage/remove.sh`（246 行），派发器只剩路由。

两个文件是 `source` 进来而不是 `exec`：交互菜单和"有新版本"横幅都需要在当前进程里调用它们。
`VERSION=` 仍然留在 `mole` 里，因为 `install.sh` 是用 sed 从这个文件里抠版本号的，别挪。

**这次抽取踩了一个坑，值得记住。** `resolve_mole_source_path` 里原本写的是
`local mole_path="${BASH_SOURCE[0]:-$0}"`。这行在派发器里是对的（`BASH_SOURCE[0]` 就是被调用的
那个 `mole`），一旦函数搬进被 source 的 lib 文件，`BASH_SOURCE[0]` 就变成 `lib/manage/update.sh`
自己，自更新会去"更新"这个 lib 文件而不是用户实际调用的 mole。全量测试里 `tests/update.bats`
三条直接红了（"targets the invoked manual install" 正是钉这个的）。

修法：`mole` 在 source 任何东西之前先记下自己 `MOLE_ENTRY_SCRIPT="${BASH_SOURCE[0]}"`，
update.sh 优先读它。`remove.sh` grep 过，没有同类依赖。

教训：搬动函数时，`BASH_SOURCE` / `$0` / `FUNCNAME` 这类**依赖"我在哪个文件里"的东西，
语义会跟着文件走**，纯文本搬运不等于行为不变。抽取前先 grep 这三个词。

### 6. Chrome / Edge / Brave 旧版本清理合并成表驱动

三个函数是同一份 Chromium 逻辑抄了三遍（同样的 `Versions/Current` 软链布局、同样的
保留 Current、同样的保留"比 Current 更新的已暂存自动更新"、同样的记账）。差异只有四处：
标签、framework 目录名、运行中探测、app 路径。

合成一个 `_clean_chromium_old_versions`，三个公开函数变成薄包装（名字必须保留，
`tests/clean_browser_versions.bats` 直接调它们）。`lib/clean/user.sh` 少了 230 行。

`clean_edge_updater_old_versions` **故意没有合进去**：它是 `sort -V` 保留最新，根本没有
Current 软链，也从不升权删除。合进去等于偷偷改它的语义。

## 二点五、复审时自己抓到并修掉的两个问题

这两个都是**我自己的改动引入的**，第一轮没发现，复审量出来的：

**ancestor symlink guard 一开始拖慢了删除主路径。** guard 每次都 fork 一个 `dirname` 再起一个
`cd -P` 子 shell，哪怕路径上根本没有软链。实测 `validate_path_for_deletion` 从 8.98ms/call
涨到 11.03ms（+23%），而它每个待删项都要跑一次，一次 2450 项的 clean 就是白白多花 5 秒。

改成两段式：先用 `[[ -L ]]` 这个 builtin 沿祖先走一遍（不 fork），只有真的撞到软链才付
`cd -P` 的代价。改完 9.17ms vs 基线 9.15ms，落回噪声范围，安全性一点没减（护栏测试仍全绿）。
基线是用 `git worktree add --detach` 拉一个干净 HEAD 量的，没动你的工作区。

**注释里写了个没量过的数字。** 我在 plutil 那处写了"defaults read 慢 2-3 倍"。实测是
4.1ms vs 2.3ms，约 1.8 倍。已改成实测值。不该把估计当事实写进代码注释。

## 三、被否决的方案（别再试）

这几条是审计里提过、但看了实现之后判断**不该做**的，记下来免得下次又绕回来：

- **容器 stub 删除不要"统一"进 `safe_remove` 漏斗。** `lib/clean/apps.sh` 里
  `_remove_verified_container_stub` 用的是裸 `rm`，看起来像是漏网之鱼。真去改了才发现：
  `should_protect_path` 对 `~/Library/Containers` 是整片保护的，一旦走漏斗，两个 stub
  路径全被拒，这个功能就静默死掉（改完当场 43/44 测试红）。已经回退成裸 `rm`，
  并把"为什么必须绕过"写进 `# SAFE:` 注释，另加一条 `tests/clean_apps.bats` 护栏测试钉住原因。
- **bash 侧不要做目录大小缓存。** APFS 的目录 mtime 不向上传播，子目录变了父目录 mtime
  不动，缓存会给出过期的可回收体积，用户看到的数字就是错的。宁可每次量。
- **README 的安装 URL 不要钉版本。** `curl main` 是这类工具的标准用法，钉了反而挡住修复。

## 四、AI 使用侧

新增 `.claude/skills/mole/SKILL.md`：给 agent 用的 mole 使用说明。

核心是三条机器可读接口（`mo analyze --json`、`mo history --json`、`mo clean --dry-run`
写出的 `~/.config/mole/clean-list.txt`）+ 安全规则（先 dry-run 再删、别解析 TUI、
别自己编 flag、保护走 whitelist 不走裸 rm）。

写之前挨个跑过验证：`--json` 两个接口的实际输出结构、clean-list.txt 的实际路径、
以及**默认删除是 permanent 不是 trash**（这条我一开始写错了，查了 `mole_delete` 才改对，
文档里现在明说"dry-run 就是你的撤销键"）。

已 symlink 到 `~/.claude/skills/mole`，本机随时可用。

## 四点五、文档同步

这批改动让几处文档变成了**事实错误**，不是"可以补充"，是"现在写的是错的"：

- `docs/SECURITY_DESIGN.md`：写着校验器"applies five independent checks"，且把 symlink
  检查描述成只看 leaf。ancestor guard 正是补这个洞的，所以 five 改 six，新增第 3 条
  详述 deny-only 语义、为什么排在 allow-list 之前、为什么 fuzz 测试的关键根故意不含 `/var`。
  文档自己那节 "When to update this document" 第一条就是"校验器新增一类检查"，属于必须更新。
  另外它引用的 `lib/clean/apps.sh:848` / `lib/core/base.sh:750` 两个行号都已漂移（后者在我
  改之前就漂了），改成按符号名引用，行号早晚会烂。
- `SECURITY_AUDIT.md`：Symlink 那节是对外承诺的安全边界，只讲 leaf 不讲 ancestor，补一行。
- `AGENTS.md`：Repository Map 补 `mole` 是纯路由 + `lib/manage/*` 的落点；Hotspot 补浏览器
  清理是表驱动、EdgeUpdater 故意不合；Pitfalls 补 `BASH_SOURCE` 搬家陷阱和"每个 du 必须
  有超时"。**注意：这个文件你自己有未提交改动（section 输出节奏那段），我只在别的段落增补，
  没碰你那一处。**
- `README.md` / `CONTRIBUTING.md` / `SECURITY.md`：逐条核对过，没有被这批改动写错的说法，
  不动。README 里 `-s latest` 的用法也回查了 `parse_args`，确实成立。

顺带把 `docs/SECURITY_DESIGN.md` 里存量的 6 个破折号清了（碰到的文件顺手清）。

## 五、验证

最后一轮（改完全部内容后跑的，不是中途的）：

```
./scripts/check.sh                      exit 0（含 shellcheck、格式、语法）
MOLE_TEST_NO_AUTH=1 ./scripts/test.sh   exit 0，1026 passed / 0 failed
go test ./...                           cmd/analyze、cmd/status、internal/units 全过
make build                              通过
```

注：跑测试时别 `| tail`，管道会吞掉真实退出码，第一遍我就是这么把一个真实的红报成绿的。

## 六、后续维护原则

- 上述安全边界、热点归属和 Shell 陷阱已经提炼进 `AGENTS.md`，后续 agent 直接读取共享规则，
  不应把本 WORKLOG 当成执行指令。
- 本文保留当时的判断和验证证据，提交拆分及当前完成度以 Git 历史为准，不维护第二份待办状态。

## 七、#1247 Homebrew 更新失败诊断

用户在 macOS 27 beta + Xcode 26.0.1 上从 Mole 1.33.0 执行 `mo update`，Homebrew
要求同代 Xcode 27，在安装 Mole 前就中止。Mole 的 Homebrew 更新路径没有自动切换安装方式，
这是有意保留的包管理边界，不能静默把 Homebrew 安装改成脚本安装。

真正需要修的是错误处理：`update_via_homebrew` 原来丢弃 `brew upgrade mole` 的退出码，
只靠输出里有没有 `Error:` 判断失败，并且只回显 `Error:` 那一行。结果既会丢掉 Homebrew
后续的 Xcode 升级说明，也可能把不含 `Error:` 的非零退出误报成更新成功。

现在改为按真实退出码判断成败，失败时完整保留 Homebrew 输出。新增两条
`tests/update.bats` 回归用例：一条钉住 Xcode 27 的完整解决说明，另一条钉住不含
`Error:` 的非零退出不得报成功。没有增加自动 fallback，也没有改变 Homebrew 安装归属。

验证：独立 detached worktree 中运行 `./scripts/check.sh --format`，再运行
`MOLE_TEST_NO_AUTH=1 bats tests/update.bats`，9/9 通过。
远端 CI 的 Validation、Check、CodeQL 与 Update Contributors 工作流也全部通过。

提交：`4daa5ef3 fix(update): preserve Homebrew failure diagnostics`，已推送 `main`。
push 后贡献者工作流自动追加 `bc15b8c2 chore: update contributors [skip ci]`，本地 `main`
已安全 fast-forward 到该远端 HEAD。

公开状态：已回复 `@rick-yao`，说明升级 Xcode、重试 Homebrew，或切换脚本安装的路径；
issue #1247 保持 open，等待下一稳定版发布边界明确后再决定是否关闭。

## 八、Agent 工作面审计

这次把项目的 Claude / Codex 工作面一起做了 deep health audit。仓库是 Standard tier，
`CLAUDE.md` 已确认是指向 `AGENTS.md` 的 symlink，因此二者不是两份规则，也不存在内容漂移。
继续保留这个结构，不改成复制文件。

实际修正：

- `AGENTS.md` 补齐项目 skill 的 canonical / symlink 关系，以及 health 扫描发现漏记的 8 个
  大文件热点边界与对应测试。`lib/core/file_ops.sh`、`cmd/analyze/scanner.go`、
  `lib/core/base.sh`、`lib/clean/apps.sh`、`lib/ui/menu_paginated.sh`、`cmd/status/view.go`、
  `lib/clean/hints.sh`、`bin/installer.sh` 现在都有明确 owner、不可破坏的边界和验证命令。
- 没有为了满足数量指标新增 `.claude/rules/`。当前共享规则约 3.5K words，仍在合理范围，
  而把 Shell / 安全规则只放进 Claude path rule 会让 Codex 丢失同一份约束，收益小于漂移风险。
- `.agents/skills/` 新增 `mole` 与 `release-flow` 的相对 symlink，和既有 `release-notes`
  一样指向 `.claude/skills/` canonical 目录。测试改成一次验证三个入口，避免未来复制分叉。
- `mole` skill 补上已经存在的 `mo status --json` 与 `mo status --watch --interval 1s`
  自动化面，并要求 watch 有明确样本数或时限，不能留下后台常驻监控。
- 两个 Claude reviewer 不再复制一份会过期的安全 / Bash 陷阱清单。现在每次先读
  `AGENTS.md` 的当前章节，再按稳定审查方法检查 diff；bash reviewer 不再写死"4 个坑"。
- release flow 明确区分 script self-update smoke 和 Homebrew downstream gate；脚本安装成功
  不能当成 Homebrew 已可升级。release-notes 改为读取 latest stable 作为格式事实源，移除
  已经不属于当前发布风格、全仓零调用的 legacy sponsor helper。
- 本机 ignored 的 `.claude/settings.local.json` 清掉一次性 commit allow 和宽泛的
  `git checkout *` / `git pull *`，只保留状态、diff、检查和测试类只读或可逆命令。

验证：agent context、deep maintainability、hotspot ownership、Markdown links 与 doc refs
全部通过；`MOLE_TEST_NO_AUTH=1 bats tests/format_on_edit_hook.bats` 3/3 通过，`make verify`
通过（golangci-lint、ShellCheck、shell syntax 与 `go test ./...` 全绿）。release-notes 的
Claude-only `disable-model-invocation` 与 Codex `allow_implicit_invocation: false` 双重门禁保留，
避免发布类 skill 被隐式执行。
