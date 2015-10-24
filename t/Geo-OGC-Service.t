# Before 'make install' is performed this script should be runnable with
# 'make test'. After 'make install' it should work as 'perl Geo-OGC-Service.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use strict;
use warnings;

use Test::More tests => 4;
use Plack::Test;
use HTTP::Request::Common;
BEGIN { use_ok('Geo::OGC::Service') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $app = Geo::OGC::Service->psgi_app('no configuration file', 'TestApp', {});

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/");
    is $res->content, "Configuration error.";
};

my $dispatch = $0;
$dispatch =~ s/\.t$/.dispatch/;

$app = Geo::OGC::Service->psgi_app($dispatch, 'TestApp', {});

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/");
    is $res->content, "Unknown service requested: ''.";
};

{
    package Geo::OGC::Service::Test;
    sub process_request {
        my ($self, $responder) = @_;
        my $writer = $responder->([200, [ 'Content-Type' => 'text/plain',
                                          'Content-Encoding' => 'UTF-8' ]]);
        $writer->write("I'm ok!");
        $writer->close;
    }
}

$app = Geo::OGC::Service->psgi_app($dispatch, 'TestApp', { test => 'Geo::OGC::Service::Test' });

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/?service=test");
    #say STDERR $res->content;
    is $res->content, "I'm ok!";
};
