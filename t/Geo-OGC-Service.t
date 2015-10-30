# Before 'make install' is performed this script should be runnable with
# 'make test'. After 'make install' it should work as 'perl Geo-OGC-Service.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use utf8;
use strict;
use warnings;
use Test::More tests => 7;
use Plack::Test;
use HTTP::Request::Common;
BEGIN { use_ok('Geo::OGC::Service') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

close(STDERR); # hide Geo::OGC::Service logging messages 

my $app = Geo::OGC::Service->new({ config => 'cannot open this', services => {} })->psgi_app;

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/");
    is $res->content, '<?xml version="1.0" encoding="UTF-8"?>'.
        '<ExceptionReport version="1.0"><Exception exceptionCode="ResourceNotFound">'.
        '<ExceptionText>Configuration error.</ExceptionText></Exception></ExceptionReport>';
};

$app = Geo::OGC::Service->new({ config => {}, services => {} })->psgi_app;

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/");
    is $res->content, '<?xml version="1.0" encoding="UTF-8"?>'.
        '<ExceptionReport version="1.0"><Exception exceptionCode="InvalidParameterValue">'.
        "<ExceptionText>'' is not a known service to this server</ExceptionText></Exception></ExceptionReport>";
};

my $config = $0;
$config =~ s/\.t$/.conf/;

$app = Geo::OGC::Service->new({ config => $config, services => {} })->psgi_app;

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/");
    is $res->content, '<?xml version="1.0" encoding="UTF-8"?>'.
        '<ExceptionReport version="1.0"><Exception exceptionCode="InvalidParameterValue">'.
        "<ExceptionText>'' is not a known service to this server</ExceptionText></Exception></ExceptionReport>";
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

$app = Geo::OGC::Service->new({ config => $config, services => { test => 'Geo::OGC::Service::Test' }})->psgi_app;

test_psgi $app, sub {
    my $cb = shift;
    my $res = $cb->(GET "/?service=test");
    #say STDERR $res->content;
    is $res->content, "I'm ok!";
};

test_psgi $app, sub {
    my $cb = shift;
    my $req = HTTP::Request->new(POST => "/");
    $req->content_type('text/xml');
    $req->content( '<?xml version="1.0" encoding="UTF-8"?>'.
                   '<request service="åäö"></request>' );
    my $res = $cb->($req);
    is $res->content, '<?xml version="1.0" encoding="UTF-8"?>'.
        '<ExceptionReport version="1.0"><Exception exceptionCode="InvalidParameterValue">'.
        "<ExceptionText>'åäö' is not a known service to this server</ExceptionText></Exception></ExceptionReport>";
};

test_psgi $app, sub {
    my $cb = shift;
    my $req = HTTP::Request->new(POST => "/");
    $req->content_type('text/xml');
    $req->content_encoding('UTF-8');
    $req->content( '<?xml version="1.0" encoding="UTF-8"?>'.
                   '<request service="test">åäö</request>' );
    my $res = $cb->($req);
    is $res->content, "I'm ok!";
};
