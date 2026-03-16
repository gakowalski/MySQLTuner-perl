use strict;
use warnings;
use Test::More;
use File::Basename;
use File::Spec;

no warnings 'once';

# Suppress warnings from mysqltuner.pl initialization if any
$SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /redefined/ };

use Cwd 'abs_path';

# Load mysqltuner.pl as a library
my $script_dir = dirname(abs_path(__FILE__));
my $script = abs_path(File::Spec->catfile($script_dir, '..', 'mysqltuner.pl'));
$main::info = '[--]';
$main::good = '[OK]';
$main::bad = '[!!]';
$main::deb = '[DG]';
$main::opt{silent} = 1;
require $script;

# 1. Test is_int
subtest 'is_int' => sub {
    ok(main::is_int("123"), "Positive integer");
    ok(main::is_int("-123"), "Negative integer");
    ok(main::is_int("0"), "Zero");
    ok(main::is_int("  456  "), "Integer with whitespace");
    ok(!main::is_int("12.3"), "Float is not int");
    ok(!main::is_int("abc"), "String is not int");
    ok(!main::is_int(""), "Empty string is not int");
    ok(!main::is_int(undef), "Undef is not int");
};

# 2. Test hr_bytes
subtest 'hr_bytes' => sub {
    is(main::hr_bytes(500), "500B", "Bytes");
    is(main::hr_bytes(1024), "1.0K", "1 KB");
    is(main::hr_bytes(1024**2), "1.0M", "1 MB");
    is(main::hr_bytes(1024**3), "1.0G", "1 GB");
    is(main::hr_bytes(1.5 * 1024**3), "1.5G", "1.5 GB");
    is(main::hr_bytes(0), "0B", "Zero bytes");
    is(main::hr_bytes("NULL"), "0B", "NULL string");
    is(main::hr_bytes(""), "0B", "Empty string");
    is(main::hr_bytes(undef), "0B", "Undef");
};

# 3. Test percentage
subtest 'percentage' => sub {
    is(main::percentage(50, 100), "50.00", "50/100 = 50.00");
    is(main::percentage(1, 3), "33.33", "1/3 = 33.33");
    is(main::percentage(0, 100), "0.00", "0/100 = 0.00");
    # Scalar context for list return (100, 0)
    is(scalar main::percentage(100, 0), "100.00", "Division by zero returns 100.00 (correct behavior for idle servers)");
};

# 4. Test hr_num
subtest 'hr_num' => sub {
    is(main::hr_num(500), "500", "Small number");
    is(main::hr_num(1000), "1K", "Thousand");
    is(main::hr_num(1000000), "1M", "Million");
    is(main::hr_num(1000000000), "1B", "Billion");
};

# 5. Test human_size
subtest 'human_size' => sub {
    is(main::human_size(1024), "1.00 KB", "1 KB");
    is(main::human_size(1024*1024), "1.00 MB", "1 MB");
};

# 6. Test arr2hash
subtest 'arr2hash' => sub {
    my %hash = ();
    my @input = (
        "key1 value1",
        "key_2\tvalue2",
        "key_with_digits_3 value3",
        "innodb_redo_log_capacity 15",
        "VERSION 8.0.32"
    );
    main::arr2hash(\%hash, \@input);
    is($hash{'key1'}, 'value1', "Simple key");
    is($hash{'key_2'}, 'value2', "Key with underscore and tab");
    is($hash{'key_with_digits_3'}, 'value3', "Key with digits and underscore");
    is($hash{'innodb_redo_log_capacity'}, '15', "Real variable name");
    is($hash{'VERSION'}, '8.0.32', "Uppercase key with digits");
};

# 7. Test Windows parsing helpers
subtest 'windows parsers' => sub {
    my $pairs = main::parse_key_value_output(
        "TotalPhysicalMemory=17179869184\n",
        "TotalVisibleMemorySize=16777216\n",
        "FreePhysicalMemory=8388608\n",
    );
    is($pairs->{TotalPhysicalMemory}, '17179869184', 'Parses key/value command output');
    is(main::extract_numeric_value('16,384 MB'), 16384, 'Extracts numeric value from formatted text');
    is(main::format_wmic_datetime('20260316112233.000000+060'), '2026-03-16 11:22:33', 'Formats WMIC datetime');

    my $ip = main::parse_windows_ipv4_from_ipconfig(
        "Windows IP Configuration\n",
        "   IPv4 Address. . . . . . . . . . . : 192.168.1.25\n",
    );
    is($ip, '192.168.1.25', 'Parses IPv4 from ipconfig output');

    my $dns = main::parse_windows_nameservers_from_ipconfig(
        "   DNS Servers . . . . . . . . . . . : 1.1.1.1\n",
        "                                       8.8.8.8\n",
    );
    is($dns, '1.1.1.1, 8.8.8.8', 'Parses DNS servers from ipconfig output');

    my @records = main::parse_wmic_record_list(
        "Caption=C:\n",
        "FreeSpace=100\n",
        "Size=200\n",
        "\n",
        "Caption=D:\n",
        "FreeSpace=300\n",
        "Size=500\n",
    );
    is(scalar @records, 2, 'Parses multiple WMIC records');
    is($records[0]->{Caption}, 'C:', 'Parses first WMIC record');
    is($records[1]->{Size}, '500', 'Parses numeric field from second WMIC record');
};

subtest 'windows mysql command quoting' => sub {
    local $main::is_win = 1;

    my $mysql_exe = 'C:\\Program Files\\MariaDB 11.8\\bin\\mysql.exe';

    is(
        main::quote_command_path($mysql_exe),
        qq("$mysql_exe"),
        'Quotes mysql executable path with spaces on Windows'
    );

    is(
        main::mysql_password_option('secret pass'),
        q(-p"secret pass"),
        'Quotes password argument for Windows shell'
    );

    is(
        main::build_mysql_alive_check_command(
            main::quote_command_path($mysql_exe),
            '--defaults-file="C:\\Program Files\\MariaDB 11.8\\my.ini" -u root -h 100.126.31.15 -P 3306'
        ),
        qq("$mysql_exe" --defaults-file="C:\\Program Files\\MariaDB 11.8\\my.ini" -u root -h 100.126.31.15 -P 3306 -Nrs -e "select 'mysqld is alive';"),
        'Builds Windows-safe mysql alive check command'
    );
};

subtest 'execute_system_command respects stderr redirection' => sub {
    local $main::opt{cloud} = 0;
    local $main::opt{container} = '0';
    local $main::opt{'ssh-host'} = '';

    my $perl = main::quote_command_path($^X);
    my $code = main::shell_quote_arg('print "stdout\n"; print STDERR "stderr\n";');
    my $out = scalar main::execute_system_command(
        qq($perl -e $code 2>@{[File::Spec->devnull()]})
    );

    is($out, "stdout\n", 'Does not re-enable stderr when the command already redirects it');
};

done_testing();
