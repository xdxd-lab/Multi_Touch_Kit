# 啟動程式、送出信號，檢查它是否「正常收尾後結束」（exit 0，而不是被信號直接終止）。
# 用法：perl signal-exit.pl MODE SIGNAL 程式 [參數…]
#   MODE = default：一般啟動；ignored：先把 SIGINT 設為忽略再 exec（等同 shell 腳本中以 & 背景執行）
# 結束碼：0 = 正常結束；1 = 被信號終止或 exit 非 0；2 = 3 秒內沒有結束
use strict;
use POSIX ":sys_wait_h";
my ($mode, $sig, @command) = @ARGV;
my $pid = fork;
if (!$pid) {
    $SIG{INT} = 'IGNORE' if $mode eq 'ignored';
    open STDOUT, '>/dev/null';
    open STDERR, '>/dev/null';
    exec @command or exit 127;
}
select(undef, undef, undef, 1.5);
kill $sig, $pid;
for (1 .. 30) {
    if (waitpid($pid, WNOHANG) == $pid) {
        my ($code, $signal) = ($? >> 8, $? & 127);
        print $signal ? "被 signal $signal 終止" : "exit $code";
        exit($signal || $code ? 1 : 0);
    }
    select(undef, undef, undef, 0.1);
}
kill 'KILL', $pid;
waitpid($pid, 0);
print "3 秒內沒有結束";
exit 2;
