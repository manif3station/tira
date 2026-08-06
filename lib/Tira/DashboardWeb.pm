package Tira::DashboardWeb;

use strict;
use warnings;

our $VERSION = '0.16';

use Encode qw(encode_utf8);
use JSON::PP qw(decode_json);
use Dancer2 appname => 'TiraDashboard';

our ( $RENDER, $DATA, $MOVE, $DETAIL );

get '/' => sub {
    content_type 'text/html; charset=UTF-8';
    return _response_bytes( $RENDER->() );
};

get '/data' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $DATA->() );
};

post '/move' => sub {
    my $payload = decode_json( request->body // '' );
    die "Invalid move payload\n" if ref($payload) ne 'HASH';
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $MOVE->($payload) );
};

get '/record' => sub {
    my %query;
    for my $pair ( split /&/, request->env->{QUERY_STRING} // '' ) {
        my ( $key, $value ) = split /=/, $pair, 2;
        next if !defined $value;
        $value =~ tr/+/ /;
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $query{$key} = $value;
    }
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $DETAIL->( \%query ) );
};

sub _response_bytes {
    my ($content) = @_;
    return utf8::is_utf8($content) ? encode_utf8($content) : $content;
}

sub build_psgi_app {
    my ( $class, %args ) = @_;
    die "Missing dashboard renderer\n" if ref( $args{render} ) ne 'CODE';
    die "Missing dashboard data provider\n" if ref( $args{data} ) ne 'CODE';
    die "Missing dashboard move provider\n" if ref( $args{move} ) ne 'CODE';
    die "Missing dashboard detail provider\n" if ref( $args{detail} ) ne 'CODE';
    $RENDER = $args{render};
    $DATA = $args{data};
    $MOVE = $args{move};
    $DETAIL = $args{detail};
    return __PACKAGE__->to_app;
}

sub serve {
    my ( $class, %args ) = @_;
    my $app = $class->build_psgi_app(
        render => $args{render}, data => $args{data}, move => $args{move}, detail => $args{detail},
    );
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
