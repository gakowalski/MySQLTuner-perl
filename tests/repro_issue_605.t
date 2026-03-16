#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Basename;
use File::Spec;
use File::Temp qw(tempdir);

no warnings 'once';

my $script = File::Spec->rel2abs(File::Spec->catfile(dirname(__FILE__), '..', 'mysqltuner.pl'));

# Mocking and loading mysqltuner.pl
{
    local @ARGV = ();
    local $SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /redefined/ };
    # We need to mock some things before requiring if they are called at top level
    no warnings 'redefine';
    no warnings 'once';
    *main::badprint = sub { print "BAD: $_[0]\n" };
    *main::goodprint = sub { print "GOOD: $_[0]\n" };
    *main::debugprint = sub { print "DEBUG: $_[0]\n" };
    *main::infoprint = sub { print "INFO: $_[0]\n" };
    *main::which = sub { return $^X };
    *main::is_remote = sub () { return 0 };
    $main::info = '[--]';
    $main::good = '[OK]';
    $main::bad = '[!!]';
    $main::deb = '[DG]';
    
    require $script;
}

my @commands_executed;
{
    no warnings 'redefine';
    no warnings 'once';
    local $SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /redefined/ };
    *main::execute_system_command = sub {
        my ($cmd) = @_;
        push @commands_executed, $cmd;
        if ($cmd =~ /--print-defaults/) {
            return "mysql --defaults-file=/tmp/my.cnf";
        }
        if ($cmd =~ /ping/ || $cmd =~ /select "mysqld is alive"/) {
            # Check if our expected faulty behavior is happening
            # Currently it will NOT have --defaults-file if it has -u/-p
            if ($cmd =~ /--defaults-file/ && $cmd =~ /-u tuneruser/ && $cmd =~ /-p'tunerpass'/) {
                return "mysqld is alive";
            }
            return "failed to connect";
        }
        return "";
    };
}

# Initialize some global variables that mysql_setup expects
$main::mysqladmincmd = $^X;
$main::mysqlcmd = $^X;
$main::is_win = 0;
$main::remotestring = "";
$main::doremote = 0;
$main::devnull = File::Spec->devnull();
foreach my $o (keys %main::CLI_METADATA) {
    my ($p) = split /\|/, $o;
    $p =~ s/[!+=:].*$//;
    $main::opt{$p} //= $main::CLI_METADATA{$o}->{default} // '0';
}
$main::opt{nobad} = 0;
$main::bad = "[!!]";

subtest 'Issue 605 - --defaults-file should allow --user and --pass' => sub {
    @commands_executed = ();
    my $tmpdir = tempdir(CLEANUP => 1);
    my $defaults_file = File::Spec->catfile($tmpdir, 'my.cnf');
    %main::opt = (
        %main::opt,
        'defaults-file' => $defaults_file,
        'user' => 'tuneruser',
        'pass' => 'tunerpass',
        'host' => '0',
        'port' => 3306,
        'mysqladmin' => $^X,
        'mysqlcmd' => $^X,
        'defaults-extra-file' => '0',
        'noask' => 1,
    );
    
    # We need to simulate that the file exists and is readable
    # In mysql_setup: if ( $opt{'defaults-file'} and -r "$opt{'defaults-file'}" )
    # Since we can't easily mock -r, we might need to create the file or mock the check.
    
    open my $fh, '>', $defaults_file or die "Could not create $defaults_file";
    print $fh "[client]\nuser=ignored\n";
    close $fh;

    # We need to mock execute_system_command to return "mysqld is alive" when it receives the correct command
    {
        no warnings 'redefine';
        *main::execute_system_command = sub {
            my ($cmd) = @_;
            push @commands_executed, $cmd;
            if (index($cmd, qq(--defaults-file="$defaults_file")) >= 0 && $cmd =~ /-u tuneruser/ && $cmd =~ /-p'tunerpass'/) {
                return "mysqld is alive";
            }
            if ($cmd =~ /--print-defaults/) { return qq(mysql --defaults-file=$defaults_file); }
            return "failed";
        };
    }

    # Now call mysql_setup
    eval { main::mysql_setup(); };
    
    my $found = grep { index($_, qq(--defaults-file="$defaults_file")) >= 0 && /-u tuneruser/ && /-p'tunerpass'/ } @commands_executed;
    ok($found, "mysql_setup should have tried to login using defaults-file AND user/pass");
    
    unless ($found) {
        diag "Commands tried:";
        diag $_ for @commands_executed;
    }
    
};

subtest 'Issue 605 - --defaults-extra-file should allow --user and --pass' => sub {
    @commands_executed = ();
    my $tmpdir = tempdir(CLEANUP => 1);
    my $extra_defaults_file = File::Spec->catfile($tmpdir, 'extra.cnf');
    %main::opt = (
        %main::opt,
        'defaults-file' => '0',
        'defaults-extra-file' => $extra_defaults_file,
        'user' => 'tuneruser',
        'pass' => 'tunerpass',
        'host' => '0',
        'port' => 3306,
        'mysqladmin' => $^X,
        'mysqlcmd' => $^X,
        'noask' => 1,
    );
    
    open my $fh, '>', $extra_defaults_file or die "Could not create $extra_defaults_file";
    print $fh "[client]\nuser=ignored\n";
    close $fh;

    # Mock success for combined command
    {
        no warnings 'redefine';
        *main::execute_system_command = sub {
            my ($cmd) = @_;
            push @commands_executed, $cmd;
            if (index($cmd, qq(--defaults-extra-file="$extra_defaults_file")) >= 0 && $cmd =~ /-u tuneruser/ && $cmd =~ /-p'tunerpass'/) {
                return "mysqld is alive";
            }
            if ($cmd =~ /--print-defaults/) { return qq(mysql --defaults-extra-file=$extra_defaults_file); }
            return "failed";
        };
    }

    eval { main::mysql_setup(); };
    
    my $found = grep { index($_, qq(--defaults-extra-file="$extra_defaults_file")) >= 0 && /-u tuneruser/ && /-p'tunerpass'/ } @commands_executed;
    ok($found, "mysql_setup should have tried to login using defaults-extra-file AND user/pass");
    
    unless ($found) {
        diag "Commands tried:";
        diag $_ for @commands_executed;
    }
    
};

done_testing();
