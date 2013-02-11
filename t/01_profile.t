use strict;
use Plack::Middleware::Profiler::KYTProf;
use Test::More;
use Plack::Test;
use Plack::Builder;
use HTTP::Request::Common;
use t::Util;

# TODO use logger to test profiling
subtest 'Can profile with default profile' => sub {
    my $app = sub {
        my $env = shift;
        return [ '200', [ 'Content-Type' => 'text/plain' ], ["Hello World"] ];
    };

    $app = Plack::Middleware::Profiler::KYTProf->wrap($app);

    test_psgi $app, sub {
        my $cb  = shift;
        my $res = $cb->( GET "/" );

        is $res->code, 200, "Response is returned successfully";
    };
};

done_testing;
