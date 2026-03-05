# Mole V1.29.0 发布前测试清单

## 1. 基础功能测试

### 1.1 主菜单和导航
- [ ] `mo` - 主菜单正常显示
- [ ] 方向键 ↑↓ 导航正常
- [ ] Enter 进入子菜单正常
- [ ] M 键显示帮助信息
- [ ] Q 键退出正常

### 1.2 版本和帮助
- [ ] `mo --version` - 显示 1.29.0
- [ ] `mo --help` - 帮助信息完整
- [ ] `mo version` - 显示详细版本信息（macOS版本、架构、SIP状态等）

---

## 2. Clean 功能测试

### 2.1 基础清理
- [ ] `mo clean` - 交互式清理正常
- [ ] `mo clean --dry-run` - 预览模式显示正确
- [ ] `mo clean --whitelist` - 白名单管理正常

### 2.2 新增功能: Xcode DeviceSupport
- [ ] 清理旧的 Xcode DeviceSupport 版本（而不是仅缓存）
- [ ] 保留当前使用的版本

### 2.3 Bug修复验证
- [ ] Go cache 清理时尊重 whitelist
- [ ] Homebrew dry-run 模式尊重 whitelist
- [ ] pip3 是 macOS stub 时跳过 pip 缓存清理
- [ ] 修复后的 ICON_WARNING 显示正确

---

## 3. Analyze 功能测试

### 3.1 基础分析
- [ ] `mo analyze` - 交互式分析正常
- [ ] `mo analyze /path` - 分析指定路径
- [ ] `mo analyze /Volumes` - 分析外部磁盘

### 3.2 新增功能: JSON 输出 (PR #533)
- [ ] `mo analyze --json` - JSON 格式输出
- [ ] `mo analyze --json /path` - 指定路径 JSON 输出
- [ ] 非 TTY 环境自动使用 JSON（如管道）: `mo analyze | cat`
- [ ] JSON 包含字段: path, total_size, file_count, items[]

---

## 4. Status 功能测试

### 4.1 基础状态
- [ ] `mo status` - 显示系统健康状态
- [ ] CPU、内存、磁盘、网络数据显示正常

### 4.2 新增功能: JSON 输出 (PR #529)
- [ ] `mo status --json` - JSON 格式输出
- [ ] 非 TTY 环境自动使用 JSON: `mo status | cat`
- [ ] JSON 包含网络数据 (PR #532 fix)
- [ ] JSON 字段验证: cpu, memory, disk, network, load_avg, uptime

---

## 5. Uninstall 功能测试

- [ ] `mo uninstall` - 应用卸载界面正常
- [ ] `mo uninstall --dry-run` - 预览卸载
- [ ] `mo uninstall --whitelist` - 白名单管理
- [ ] 卸载后能正确发现相关文件

---

## 6. Optimize 功能测试

- [ ] `mo optimize` - 系统优化正常
- [ ] `mo optimize --dry-run` - 预览模式
- [ ] `mo optimize --whitelist` - 白名单管理

---

## 7. Purge 功能测试

- [ ] `mo purge` - 项目清理正常
- [ ] `mo purge --dry-run` - 预览模式
- [ ] `mo purge --paths` - 配置扫描目录
- [ ] dry-run 不计入失败移除 (bug fix验证)

---

## 8. Installer 功能测试

- [ ] `mo installer` - 安装包清理正常
- [ ] `mo installer --dry-run` - 预览模式

---

## 9. TouchID 功能测试

- [ ] `mo touchid` - TouchID 配置界面
- [ ] `mo touchid enable --dry-run` - 预览模式

---

## 10. Update 功能测试

### 10.1 基础更新
- [ ] `mo update` - 检查更新（当前已是最新版）
- [ ] `mo update --force` - 强制重新安装

### 10.2 新增功能: Nightly 更新 (PR #517)
- [ ] `mo update --nightly` - 安装 nightly 版本
- [ ] nightly 安装后 `mo --version` 显示 commit hash
- [ ] nightly 安装后 `mo version` 显示 "Channel: Nightly (xxxxxx)"
- [ ] Homebrew 安装时 `mo update --nightly` 应被拒绝

### 10.3 Bug修复验证
- [ ] 更新时保持 sudo 会话活跃
- [ ] 避免 SIGPIPE 在 Homebrew 检测中

---

## 11. Completion 功能测试

- [ ] `mo completion` - 补全脚本安装
- [ ] `mo completion --dry-run` - 预览模式

---

## 12. Remove 功能测试

- [ ] `mo remove --dry-run` - 预览移除 Mole

---

## 13. 边界情况测试

### 13.1 安全性
- [ ] 不删除 /System、/Library/Apple 等受保护路径
- [ ] 不删除 com.apple.* 系统文件
- [ ] dry-run 模式绝不执行实际删除

### 13.2 并发和超时
- [ ] 长时间运行的命令有超时处理
- [ ] 网络请求有超时处理

### 13.3 错误处理
- [ ] 网络不可用时的优雅降级
- [ ] 权限不足时的正确提示
- [ ] 文件不存在时不报错

---

## 14. 多场景测试

### 14.1 不同安装方式
- [ ] 脚本安装的功能正常
- [ ] Homebrew 安装的功能正常（如果可测）

### 14.2 不同 macOS 版本
- [ ] 在支持的 macOS 版本上测试

### 14.3 不同架构
- [ ] Apple Silicon (arm64) - 测试通过
- [ ] Intel (x86_64) - 如可测

---

## 15. JSON 输出格式验证

### 15.1 Analyze JSON 结构
```bash
mo analyze --json /tmp 2>/dev/null | jq '.'
```
应包含:
- [ ] path
- [ ] total_size
- [ ] file_count
- [ ] items (name, path, size, size_human, count)

### 15.2 Status JSON 结构
```bash
mo status --json 2>/dev/null | jq '.'
```
应包含:
- [ ] cpu (usage, cores)
- [ ] memory (total, used, free, cached, usage_percent)
- [ ] disk (total, used, free, usage_percent)
- [ ] network (interfaces with rx_bytes, tx_bytes)
- [ ] load_avg (1min, 5min, 15min)
- [ ] uptime

---

## 快速验证命令

```bash
# 1. 版本检查
mo --version  # 应为 1.29.0

# 2. 核心功能快速测试
mo clean --dry-run
mo analyze --json /tmp 2>/dev/null | head -20
mo status --json 2>/dev/null | jq '.'

# 3. 测试脚本验证
./scripts/test.sh

# 4. 代码格式检查
./scripts/check.sh --format
```

---

## 测试通过标准

- [ ] 所有勾选测试通过
- [ ] 无崩溃、无异常退出
- [ ] JSON 输出格式正确
- [ ] dry-run 模式安全
- [ ] 测试脚本全部通过: 464 tests, 0 failures
