#!perl

use strict;
use warnings;
use IO::Socket::INET;
use IO::Socket::SSL;
do './testlib.pl' || do './t/testlib.pl' || die "no testlib";

$|=1;
my @tests = qw( start stop start stop:write close );
print "1..26\n";

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen => 2,
) || die "not ok # tcp listen failed: $!\n";
print "ok # listen\n";
my $saddr = $server->sockhost.':'.$server->sockport;

defined( my $pid = fork() ) || die $!;
$pid ? server():client();
wait;
exit(0);


sub client {
    close($server);
    my $client = IO::Socket::INET->new($saddr) or
	die "not ok # client connect: $!\n";
    $client->autoflush;
    print "ok # client connect\n";

    for my $test (@tests) {
	alarm(15);
	#print STDERR "begin test $test\n";
	if ( $test eq 'start' ) {
	    syswrite($client,"start\n");
	    sleep(1); # avoid race condition, if client calls start but server is not yet available

	    #print STDERR ">>$$(client) start\n";
	    IO::Socket::SSL->start_SSL($client, SSL_verify_mode => 0 )
		|| die "not ok # client::start_SSL: $SSL_ERROR\n";
	    #print STDERR "<<$$(client) start\n";
	    print "ok # client::start_SSL\n";

	    ref($client) eq "IO::Socket::SSL" or print "not ";
	    print "ok # client::class=".ref($client)."\n";

	} elsif ( $test eq 'stop' ) {
	    syswrite($client,"stop\n");
	    $client->stop_SSL || die "not ok # client::stop_SSL\n";
	    print "ok # client::stop_SSL\n";

	    ref($client) eq "IO::Socket::INET" or print "not ";
	    print "ok # client::class=".ref($client)."\n";

	} elsif ( $test eq 'stop:write' ) {
	    syswrite($client,"stop:write\n");
	    $client->stop_SSL(SSL_fast_shutdown => 1)
		|| die "not ok # client::stop_SSL\n";
	    print "ok # client::stop_SSL(SSL_fast_shutdown => 1)\n";

	    ref($client) eq "IO::Socket::SSL" or print "not ";
	    print "ok # client::class=".ref($client)."\n";

	    ${*$client}{_SSL_write_closed} or print "not ";
	    print "ok # client _SSL_write_closed\n";

	    # this should be send in plain
	    syswrite($client, "after stop:write\n");

	} elsif ( $test eq 'close' ) {
	    syswrite($client,"close\n");
	    my $class = ref($client);
	    $client->close || die "not ok # client::close\n";
	    print "ok # client::close\n";

	    ref($client) eq $class or print "not ";
	    print "ok # client::class=".ref($client)."\n";
	    last;
	}
	#print STDERR "cont test $test\n";

	sysread($client, my $line, 1024) or return;
	die "'$line'" if $line ne "OK\n";
    }
}


sub server {
    my $client = $server->accept || die $!;
    $client->autoflush;
    my $peer_shutdown;
    while (1) {
	alarm(15);
	sysread($client, my $line, 1024) or last;
	chomp($line);
	if ( $line eq 'start' ) {
	    #print STDERR ">>$$ start\n";
	    IO::Socket::SSL->start_SSL( $client,
		SSL_server => 1,
		SSL_cert_file => "t/certs/client-cert.pem",
		SSL_key_file => "t/certs/client-key.pem",
	    ) || die "not ok # server::start_SSL: $SSL_ERROR\n";
	    #print STDERR "<<$$ start\n";

	    ref($client) eq "IO::Socket::SSL" or print "not ";
	    print "ok # server::class=".ref($client)."\n";
	    syswrite($client,"OK\n");

	} elsif ( $line eq 'stop' ) {
	    $client->stop_SSL || die "not ok # server::stop_SSL\n";
	    print "ok # server::stop_SSL\n";

	    ref($client) eq "IO::Socket::INET" or print "not ";
	    print "ok # server class=".ref($client)."\n";
	    syswrite($client,"OK\n");

	} elsif ( $line eq 'stop:write' ) {
	    # expect 0
	    my $n = sysread($client, $line, 1);
	    print "not " if !defined $n or $n !=0;
	    print "ok # server read ssl n=0\n";

	    # implicit close will not remove _SSL_object
	    ${*$client}{_SSL_object} or print "not ";
	    print "ok # server _SSL_object\n";

	    # read and write is marked as automatic shutdown
	    ${*$client}{_SSL_read_closed} == -1 or print "not ";
	    print "ok # server _SSL_read_closed == -1\n";
	    ${*$client}{_SSL_write_closed} == -1 or print "not ";
	    print "ok # server _SSL_write_closed == -1\n";

	    # not implicitly downgraded
	    ref($client) eq "IO::Socket::SSL" or print "not ";
	    print "ok # server class=".ref($client)."\n";

	    # but will show as not having (anymore) SSL
	    $client->is_SSL and print "not ";
	    print "ok # is_SSL returns false\n";

	    # write before explict stop_SSL will fail with EPERM
	    $n = syswrite($client, 'foo', 3);
	    print "not " if defined($n) or not $!{EPERM};
	    print "ok # write results in undef/EPERM\n";

	    # same with read
	    $n = sysread($client, $line, 100);
	    print "not " if defined($n) or not $!{EPERM};
	    print "ok # read results in undef/EPERM\n";

	    # will both work after explicit stop_SSL
	    $client->stop_SSL();

	    # downgraded
	    ref($client) eq "IO::Socket::INET" or print "not ";
	    print "ok # server class=".ref($client)."\n";

	    $n = sysread($client, $line, 100);
	    print "not " if ! $line || $line ne "after stop:write\n";
	    print "ok # server plain read: $line\n";

	    $n = syswrite($client,"OK\n");
	    print "not " unless defined $n and $n>0;
	    print "ok # plain write\n";

	} elsif ( $line eq 'close' ) {
	    my $class = ref($client);
	    $client->close || die "not ok # server::close\n";
	    print "ok # server::close\n";

	    ref($client) eq $class or print "not ";
	    print "ok # server class=".ref($client)."\n";
	    last;
	}
    }
}
