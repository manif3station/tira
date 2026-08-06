package Tira::DashboardWeb;

use strict;
use warnings;

our $VERSION = '0.16';

use Dancer2 appname => 'TiraDashboard';

our ( $RENDER, $DATA );

get '/' => sub {
    content_type 'text/html; charset=UTF-8';
    return $RENDER->();
};

get '/data' => sub {
    content_type 'application/json; charset=UTF-8';
    return $DATA->();
};

sub build_psgi_app {
    my ( $class, %args ) = @_;
    die "Missing dashboard renderer\n" if ref( $args{render} ) ne 'CODE';
    die "Missing dashboard data provider\n" if ref( $args{data} ) ne 'CODE';
    $RENDER = $args{render};
    $DATA = $args{data};
    return __PACKAGE__->to_app;
}

sub serve {
    my ( $class, %args ) = @_;
    my $app = $class->build_psgi_app( render => $args{render}, data => $args{data} );
    require Plack::Runner;
    my $runner = Plack::Runner->new;
    $runner->parse_options(
        '--server', 'HTTP::Server::PSGI', '--host', $args{host},
        '--port', $args{port}, '--env', 'deployment',
    );
    $runner->run($app);
    return 1;
}

1;

__END__

=head1 NAME

Tira::DashboardWeb - Dancer2 PSGI adapter for live Tira boards

=head1 DESCRIPTION

Builds a minimal Dancer2 application whose root route regenerates and returns
the self-contained Tira dashboard HTML. C<serve> runs that PSGI application
through Plack's bundled standalone server at a validated CLI bind address.

=head1 METHODS

=head2 build_psgi_app

Accepts a C<render> coderef and returns the Dancer2 PSGI application.

=head2 serve

Runs the application using the supplied C<host>, C<port>, and C<render> values.

=cut
