package Tira::DashboardWeb;

use strict;
use warnings;

our $VERSION = '0.18';

use Encode qw(encode_utf8);
use JSON::PP ();
use Dancer2 appname => 'TiraDashboard';

our ( $RENDER, $DATA, $MOVE, $DETAIL, $UPDATE, $COMMENT_ADD, $COMMENT_UPDATE, $COMMENT_REMOVE, $PEOPLE,
      $ATTACHMENT_FETCH, $ATTACHMENT_ADD, $ATTACHMENT_REMOVE );

get '/' => sub {
    content_type 'text/html; charset=UTF-8';
    return _response_bytes( $RENDER->() );
};

get '/data' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $DATA->() );
};

post '/move' => sub {
    my $payload = JSON::PP::decode_json( request->body // '' );
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

get '/people' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $PEOPLE->() );
};

post '/update' => sub { return _mutation( \$UPDATE ) };
post '/comment/add' => sub { return _mutation( \$COMMENT_ADD ) };
post '/comment/update' => sub { return _mutation( \$COMMENT_UPDATE ) };
post '/comment/remove' => sub { return _mutation( \$COMMENT_REMOVE ) };
post '/attachment/add' => sub { return _mutation( \$ATTACHMENT_ADD ) };
post '/attachment/remove' => sub { return _mutation( \$ATTACHMENT_REMOVE ) };

get '/attachment' => sub {
    my %query;
    for my $pair ( split /&/, request->env->{QUERY_STRING} // '' ) {
        my ( $key, $value ) = split /=/, $pair, 2;
        next if !defined $value;
        $value =~ tr/+/ /;
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $query{$key} = $value;
    }
    my $payload = eval { $ATTACHMENT_FETCH->( \%query ) };
    if ( !defined $payload ) {
        status 404;
        content_type 'text/plain; charset=UTF-8';
        my $error = $@ || 'Attachment not found';
        $error =~ s/(?: at \S+ line \d+\.?)?\s*\z//s;
        return _response_bytes($error);
    }
    content_type( $payload->{content_type} // 'application/octet-stream' );
    my $name = $payload->{filename} // 'attachment.bin';
    $name =~ s/["\r\n]//g;
    response->header( 'Content-Disposition' =>
      ( $payload->{inline} ? 'inline' : 'attachment' ) . qq{; filename="$name"} );
    return _response_bytes( $payload->{content} );
};

# Dialog mutations report failures as structured JSON instead of an HTML
# error page, so the dialog can show the engine's validation message inline.
sub _mutation {
    my ($provider) = @_;
    content_type 'application/json; charset=UTF-8';
    my $result = eval {
        my $body = request->body // '';
        my $payload = JSON::PP::decode_json( utf8::is_utf8($body) ? encode_utf8($body) : $body );
        ${$provider}->($payload);
    };
    if ( !defined $result ) {
        my $error = $@ || 'Mutation failed';
        $error =~ s/(?: at \S+ line \d+\.?)?\s*\z//s;
        status 422;
        return _response_bytes(
            JSON::PP->new->canonical->encode( { ok => JSON::PP::false, error => $error } )
        );
    }
    return _response_bytes($result);
}

sub _response_bytes {
    my ($content) = @_;
    return utf8::is_utf8($content) ? encode_utf8($content) : $content;
}

my @PROVIDERS = (
    [ render => \$RENDER, 'renderer' ],
    [ data => \$DATA, 'data provider' ],
    [ move => \$MOVE, 'move provider' ],
    [ detail => \$DETAIL, 'detail provider' ],
    [ update => \$UPDATE, 'update provider' ],
    [ comment_add => \$COMMENT_ADD, 'comment add provider' ],
    [ comment_update => \$COMMENT_UPDATE, 'comment update provider' ],
    [ comment_remove => \$COMMENT_REMOVE, 'comment remove provider' ],
    [ people => \$PEOPLE, 'people provider' ],
    [ attachment_fetch => \$ATTACHMENT_FETCH, 'attachment fetch provider' ],
    [ attachment_add => \$ATTACHMENT_ADD, 'attachment add provider' ],
    [ attachment_remove => \$ATTACHMENT_REMOVE, 'attachment remove provider' ],
);

sub build_psgi_app {
    my ( $class, %args ) = @_;
    for my $provider (@PROVIDERS) {
        my ( $name, $slot, $label ) = @{$provider};
        die "Missing dashboard $label\n" if ref( $args{$name} ) ne 'CODE';
        ${$slot} = $args{$name};
    }
    return __PACKAGE__->to_app;
}

sub serve {
    my ( $class, %args ) = @_;
    my $app = $class->build_psgi_app(
        map { $_->[0] => $args{ $_->[0] } } @PROVIDERS
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
the self-contained Tira dashboard HTML. Data, record, and people routes feed
the live board and its Jira-style card dialog; update and comment routes apply
validated record mutations and answer failures as structured 422 JSON so the
dialog can surface the engine's message. C<serve> runs the PSGI application
through Plack's bundled standalone server at a validated CLI bind address.

=head1 METHODS

=head2 build_psgi_app

Accepts render, data, move, detail, update, comment_add, comment_update,
comment_remove, people, attachment_fetch, attachment_add, and
attachment_remove coderefs and returns the Dancer2 PSGI application. The
attachment fetch provider returns a typed payload that the GET /attachment
route streams with its content type and disposition; unknown attachments
answer 404.

=head2 serve

Runs the application using the supplied C<host>, C<port>, and provider values.

=cut
