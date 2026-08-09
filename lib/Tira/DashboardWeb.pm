package Tira::DashboardWeb;

use strict;
use warnings;

our $VERSION = '0.96';

use Encode qw(decode_utf8 encode_utf8);
use JSON::PP ();
use Dancer2 appname => 'TiraDashboard';

our ( $RENDER, $DATA, $MOVE, $DETAIL, $CREATE, $UPDATE, $SEARCH, $COMMENT_ADD, $COMMENT_UPDATE, $COMMENT_REMOVE, $PEOPLE,
      $ATTACHMENT_FETCH, $ATTACHMENT_ADD, $ATTACHMENT_REMOVE, $CHECKLIST_ADD, $CHECKLIST_UPDATE,
      $LINK_TYPES, $HIERARCHY_LINK, $HIERARCHY_UNLINK, $SUBITEM_LINK, $SUBITEM_UNLINK, $LINK_ADD, $LINK_REMOVE,
      $COLUMNS, $COLUMN_APPLY, $QUESTION_ANSWER, $QUESTION_MARK );

get '/' => sub {
    content_type 'text/html; charset=UTF-8';
    return _response_bytes( $RENDER->() );
};

get '/data' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $DATA->() );
};

post '/move' => sub {
    my $payload = Tira::json_decode( request->body // '' );
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

post '/create' => sub { return _mutation( \$CREATE ) };
post '/columns/apply' => sub { return _mutation( \$COLUMN_APPLY ) };
post '/question/answer' => sub { return _mutation( \$QUESTION_ANSWER ) };
post '/question/mark' => sub { return _mutation( \$QUESTION_MARK ) };
post '/update' => sub { return _mutation( \$UPDATE ) };
post '/comment/add' => sub { return _mutation( \$COMMENT_ADD ) };
post '/comment/update' => sub { return _mutation( \$COMMENT_UPDATE ) };
post '/comment/remove' => sub { return _mutation( \$COMMENT_REMOVE ) };
post '/attachment/add' => sub { return _mutation( \$ATTACHMENT_ADD ) };
post '/attachment/remove' => sub { return _mutation( \$ATTACHMENT_REMOVE ) };
post '/checklist/add' => sub { return _mutation( \$CHECKLIST_ADD ) };
post '/checklist/update' => sub { return _mutation( \$CHECKLIST_UPDATE ) };
post '/hierarchy/link' => sub { return _mutation( \$HIERARCHY_LINK ) };
post '/hierarchy/unlink' => sub { return _mutation( \$HIERARCHY_UNLINK ) };
post '/subitem/link' => sub { return _mutation( \$SUBITEM_LINK ) };
post '/subitem/unlink' => sub { return _mutation( \$SUBITEM_UNLINK ) };
post '/link/add' => sub { return _mutation( \$LINK_ADD ) };
post '/link/remove' => sub { return _mutation( \$LINK_REMOVE ) };

get '/columns' => sub {
    my ($type) = ( request->env->{QUERY_STRING} // '' ) =~ /(?:\A|&)type=([^&]*)/;
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $COLUMNS->( { type => $type } ) );
};

get '/search' => sub {
    my %query;
    for my $pair ( split /&/, request->env->{QUERY_STRING} // '' ) {
        my ( $key, $value ) = split /=/, $pair, 2;
        next if !defined $value;
        $value =~ tr/+/ /;
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $query{$key} = decode_utf8($value);
    }
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $SEARCH->( \%query ) );
};

get '/link-types' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $LINK_TYPES->() );
};

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
    my $bytes = _response_bytes( $payload->{content} );
    my $length = length $bytes;
    response->header( 'Accept-Ranges' => 'bytes' );
    my $range = request->header('Range');
    # Safari refuses to play media without byte-range support, and every
    # player needs it for seeking.
    if ( defined $range && $range =~ /\Abytes=(\d*)-(\d*)\z/ && $length ) {
        my ( $start, $end ) = ( $1, $2 );
        if ( $start eq '' && $end ne '' ) {
            $start = $length - $end;
            $start = 0 if $start < 0;
            $end = $length - 1;
        }
        else {
            $start = 0 + ( $start || 0 );
            $end = ( $end ne '' && $end < $length ) ? 0 + $end : $length - 1;
        }
        if ( $start <= $end && $start < $length ) {
            status 206;
            response->header( 'Content-Range' => "bytes $start-$end/$length" );
            return substr( $bytes, $start, $end - $start + 1 );
        }
    }
    return $bytes;
};

# Dialog mutations report failures as structured JSON instead of an HTML
# error page, so the dialog can show the engine's validation message inline.
sub _mutation {
    my ($provider) = @_;
    content_type 'application/json; charset=UTF-8';
    my $result = eval {
        my $body = request->body // '';
        my $payload = Tira::json_decode( utf8::is_utf8($body) ? encode_utf8($body) : $body );
        ${$provider}->($payload);
    };
    if ( !defined $result ) {
        my $error = $@ || 'Mutation failed';
        $error =~ s/(?: at \S+ line \d+\.?)?\s*\z//s;
        status 422;
        my %failure = ( ok => JSON::PP::false, error => $error );
        $failure{conflict} = JSON::PP::true if $error =~ /\AConflict:/;
        return _response_bytes( Tira::json_object()->canonical->encode( \%failure ) );
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
    [ create => \$CREATE, 'create provider' ],
    [ search => \$SEARCH, 'search provider' ],
    [ columns => \$COLUMNS, 'columns provider' ],
    [ question_answer => \$QUESTION_ANSWER, 'question answer provider' ],
    [ question_mark => \$QUESTION_MARK, 'question mark provider' ],
    [ column_apply => \$COLUMN_APPLY, 'column layout provider' ],
    [ update => \$UPDATE, 'update provider' ],
    [ comment_add => \$COMMENT_ADD, 'comment add provider' ],
    [ comment_update => \$COMMENT_UPDATE, 'comment update provider' ],
    [ comment_remove => \$COMMENT_REMOVE, 'comment remove provider' ],
    [ people => \$PEOPLE, 'people provider' ],
    [ attachment_fetch => \$ATTACHMENT_FETCH, 'attachment fetch provider' ],
    [ attachment_add => \$ATTACHMENT_ADD, 'attachment add provider' ],
    [ attachment_remove => \$ATTACHMENT_REMOVE, 'attachment remove provider' ],
    [ checklist_add => \$CHECKLIST_ADD, 'checklist add provider' ],
    [ checklist_update => \$CHECKLIST_UPDATE, 'checklist update provider' ],
    [ link_types => \$LINK_TYPES, 'link types provider' ],
    [ hierarchy_link => \$HIERARCHY_LINK, 'hierarchy link provider' ],
    [ hierarchy_unlink => \$HIERARCHY_UNLINK, 'hierarchy unlink provider' ],
    [ subitem_link => \$SUBITEM_LINK, 'subitem link provider' ],
    [ subitem_unlink => \$SUBITEM_UNLINK, 'subitem unlink provider' ],
    [ link_add => \$LINK_ADD, 'link add provider' ],
    [ link_remove => \$LINK_REMOVE, 'link remove provider' ],
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
