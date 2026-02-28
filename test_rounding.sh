bytes_to_human_new() {
    local bytes="$1"
    if ((bytes >= 1000000000)); then
        local scaled=$(((bytes * 100 + 500000000) / 1000000000))
        printf "%d.%02dGB\n" $((scaled / 100)) $((scaled % 100))
    elif ((bytes >= 1000000)); then
        local scaled=$(((bytes * 10 + 500000) / 1000000))
        printf "%d.%01dMB\n" $((scaled / 10)) $((scaled % 10))
    elif ((bytes >= 1000)); then
        printf "%dKB\n" $(((bytes + 500) / 1000))
    else
        printf "%dB\n" "$bytes"
    fi
}
bytes_to_human_new 12187977120
bytes_to_human_new 12999000000
bytes_to_human_new 36281810
