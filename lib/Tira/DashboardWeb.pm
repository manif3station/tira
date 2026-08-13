package Tira::DashboardWeb;

use strict;
use warnings;

our $VERSION = '1.05';

use Encode qw(decode_utf8 encode_utf8);
use Cpanel::JSON::XS ();
use Dancer2 appname => 'TiraDashboard';

our ( $RENDER, $DATA, $MOVE, $DETAIL, $CREATE, $UPDATE, $SEARCH, $COMMENT_ADD, $COMMENT_UPDATE, $COMMENT_REMOVE, $PEOPLE,
      $ATTACHMENT_FETCH, $ATTACHMENT_ADD, $ATTACHMENT_REMOVE, $ATTACHMENT_DISCARD, $CHECKLIST_ADD, $CHECKLIST_UPDATE,
      $LINK_TYPES, $HIERARCHY_LINK, $HIERARCHY_UNLINK, $SUBITEM_LINK, $SUBITEM_UNLINK, $LINK_ADD, $LINK_REMOVE,
      $COLUMNS, $COLUMN_APPLY, $QUESTION_ANSWER, $QUESTION_MARK, $QUESTION_ATTACH,
      $LOGIN_START, $LOGIN_REGISTER, $SESSION_RESUME, $SESSION_PEEK, $SESSION_END, $LOGIN_PAGE,
      $WORK_LOG, $POLICE_LOG );

our $COOKIE = 'tira_session';

# The board fetches its own routes from its own scripts. A stranger there must
# get a refusal they can react to, not a login page rendered into a card - so
# only the front door serves the page, and everything else answers 401 JSON.
my %PUBLIC = map { $_ => 1 } qw(/login /logout);

# The board polls this on a timer whether anybody is at the keyboard or not.
# Reading a session through it must not push the expiry out, or a tab left open
# overnight would keep itself signed in for ever.
my %POLLED = ( '/data' => 1 );

sub _cookie_token {
    my $header = request->header('Cookie') // '';
    my ($token) = $header =~ /(?:\A|;)\s*\Q$COOKIE\E=([^;]*)/;
    return $token;
}

sub _session_cookie {
    my ( $value, %args ) = @_;
    my @parts = ( "$COOKIE=$value", 'Path=/', 'HttpOnly', 'SameSite=Lax' );
    push @parts, 'Max-Age=0', 'Expires=Thu, 01 Jan 1970 00:00:00 GMT' if $args{clear};
    return join '; ', @parts;
}

sub _refuse {
    my ($message) = @_;
    status 401;
    content_type 'application/json; charset=UTF-8';
    return _response_bytes(
        Tira::json_object()->canonical->encode(
            { ok => Cpanel::JSON::XS::false, error => $message // 'Sign in required' } ) );
}

hook before => sub {
    my $path = request->path;
    return if $PUBLIC{$path};
    my $token = _cookie_token();
    my $reader = $POLLED{$path} ? $SESSION_PEEK : $SESSION_RESUME;
    # Asked even when there is no cookie at all, so the one place that decides
    # whether somebody is signed in is the session layer rather than this hook.
    # An absent or empty token resolves to nobody there, which is what the
    # stranger checks in the gate test prove.
    my $session = Tira::json_decode( $reader->( { token => $token // '' } ) );
    if ( ref $session eq 'HASH' && defined $session->{person} ) {
        var signed_in => $session->{person};
        return;
    }

    # The front door is the one place a person rather than a script is
    # looking, so it gets the login page instead of a refusal.
    if ( $path eq '/' ) {
        content_type 'text/html; charset=UTF-8';

        # Handed over as characters rather than bytes. A halted response is
        # encoded by Dancer2 on its way out, so encoding it here as well is
        # what turns an em dash into mojibake - which is exactly how
        # went wrong, in a different place.
        halt( $LOGIN_PAGE->() );
    }
    halt( _refuse() );
};

post '/login' => sub {
    my $payload = eval { Tira::json_decode( request->body // '' ) };
    $payload = {} if ref $payload ne 'HASH';
    content_type 'application/json; charset=UTF-8';

    # Trust on first use, which is what he asked for: a person who has never
    # signed in claims a password by typing one, and is signed in with it
    # rather than being made to type it twice.
    my $answer = Tira::json_decode( $LOGIN_START->($payload) );
    if ( !$answer->{ok} ) {
        my $claimed = Tira::json_decode( $LOGIN_REGISTER->($payload) );
        $answer = $claimed if $claimed->{ok};
    }

    # A person who does not exist and a wrong password answer identically, so
    # the page cannot be used to find out who is on the project.
    return _refuse('Sign in failed') if !$answer->{ok};
    response->header( 'Set-Cookie' => _session_cookie( $answer->{token} ) );
    return _response_bytes(
        Tira::json_object()->canonical->encode(
            { ok => Cpanel::JSON::XS::true, claimed => $answer->{claimed} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false } ) );
};

post '/logout' => sub {
    my $token = _cookie_token();
    $SESSION_END->( { token => $token } ) if defined $token;
    response->header( 'Set-Cookie' => _session_cookie( '', clear => 1 ) );
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( Tira::json_object()->canonical->encode( { ok => Cpanel::JSON::XS::true } ) );
};

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
    return _response_bytes( $MOVE->( _attributed($payload) ) );
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

# Its own route, asked for when the section is expanded rather than when the
# card is opened.
get '/worklog' => sub {
    my ($ref) = ( request->env->{QUERY_STRING} // '' ) =~ /(?:\A|&)ref=([^&]*)/;
    $ref =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge if defined $ref;
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $WORK_LOG->( { ref => $ref } ) );
};

# What police has said about one card. Read-only by construction: there is no
# route that writes here, because police writes this log and nobody else may.
get '/policelog' => sub {
    my ($ref) = ( request->env->{QUERY_STRING} // '' ) =~ /(?:\A|&)ref=([^&]*)/;
    $ref =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge if defined $ref;
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $POLICE_LOG->( { ref => $ref } ) );
};

get '/people' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $PEOPLE->() );
};

post '/create' => sub { return _mutation( \$CREATE ) };
post '/columns/apply' => sub { return _mutation( \$COLUMN_APPLY ) };
post '/question/answer' => sub { return _mutation( \$QUESTION_ANSWER ) };
post '/question/mark' => sub { return _mutation( \$QUESTION_MARK ) };
post '/question/attach' => sub { return _mutation( \$QUESTION_ATTACH ) };
post '/update' => sub { return _mutation( \$UPDATE ) };
post '/comment/add' => sub { return _mutation( \$COMMENT_ADD ) };
post '/comment/update' => sub { return _mutation( \$COMMENT_UPDATE ) };
post '/comment/remove' => sub { return _mutation( \$COMMENT_REMOVE ) };
post '/attachment/add' => sub { return _mutation( \$ATTACHMENT_ADD ) };
post '/attachment/remove' => sub { return _mutation( \$ATTACHMENT_REMOVE ) };
post '/attachment/discard' => sub { return _mutation( \$ATTACHMENT_DISCARD ) };
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

        ${$provider}->( _attributed($payload) );
    };
    if ( !defined $result ) {
        my $error = $@ || 'Mutation failed';
        $error =~ s/(?: at \S+ line \d+\.?)?\s*\z//s;
        status 422;
        my %failure = ( ok => Cpanel::JSON::XS::false, error => $error );
        $failure{conflict} = Cpanel::JSON::XS::true if $error =~ /\AConflict:/;
        return _response_bytes( Tira::json_object()->canonical->encode( \%failure ) );
    }
    return _response_bytes($result);
}

# Who is signed in travels with every change made through the board, so the
# engine can record who acted. An author or reporter named explicitly still
# wins - an agent acting on somebody's behalf is a real case, and this is a
# default rather than a straitjacket.
#
# Every route that changes something goes through here. The move route once
# did not, and so the one thing the owner most wanted recorded - who moved a
# card - was the one thing that stayed anonymous.
sub _attributed {
    my ($payload) = @_;
    $payload->{_signed_in} = var('signed_in')
      if ref $payload eq 'HASH' && defined var('signed_in');
    return $payload;
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
    [ question_attach => \$QUESTION_ATTACH, 'question attach provider' ],
    [ column_apply => \$COLUMN_APPLY, 'column layout provider' ],
    [ update => \$UPDATE, 'update provider' ],
    [ comment_add => \$COMMENT_ADD, 'comment add provider' ],
    [ comment_update => \$COMMENT_UPDATE, 'comment update provider' ],
    [ comment_remove => \$COMMENT_REMOVE, 'comment remove provider' ],
    [ people => \$PEOPLE, 'people provider' ],
    [ attachment_fetch => \$ATTACHMENT_FETCH, 'attachment fetch provider' ],
    [ attachment_add => \$ATTACHMENT_ADD, 'attachment add provider' ],
    [ attachment_remove => \$ATTACHMENT_REMOVE, 'attachment remove provider' ],
    [ attachment_discard => \$ATTACHMENT_DISCARD, 'attachment discard provider' ],
    [ checklist_add => \$CHECKLIST_ADD, 'checklist add provider' ],
    [ checklist_update => \$CHECKLIST_UPDATE, 'checklist update provider' ],
    [ link_types => \$LINK_TYPES, 'link types provider' ],
    [ hierarchy_link => \$HIERARCHY_LINK, 'hierarchy link provider' ],
    [ hierarchy_unlink => \$HIERARCHY_UNLINK, 'hierarchy unlink provider' ],
    [ subitem_link => \$SUBITEM_LINK, 'subitem link provider' ],
    [ subitem_unlink => \$SUBITEM_UNLINK, 'subitem unlink provider' ],
    [ link_add => \$LINK_ADD, 'link add provider' ],
    [ link_remove => \$LINK_REMOVE, 'link remove provider' ],
    [ login_start => \$LOGIN_START, 'login start provider' ],
    [ login_register => \$LOGIN_REGISTER, 'login register provider' ],
    [ session_resume => \$SESSION_RESUME, 'session resume provider' ],
    [ session_peek => \$SESSION_PEEK, 'session peek provider' ],
    [ session_end => \$SESSION_END, 'session end provider' ],
    [ login_page => \$LOGIN_PAGE, 'login page provider' ],
    [ work_log => \$WORK_LOG, 'work log provider' ],
    [ police_log => \$POLICE_LOG, 'police log provider' ],
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

    # One server, whether or not there is a certificate. It used to be
    # HTTP::Server::PSGI without TLS, which handles one connection at a time -
    # a reasonable choice when a board was a page somebody loaded now and then,
    # and the wrong one now that the board polls itself every sixty seconds,
    # fetches a work log when somebody expands it, and sits open on a phone.
    #
    # His board was found listening, its process alive, and answering nothing:
    # one connection that never finished its request had stopped everything
    # behind it. A board that accepts a connection and never answers looks
    # exactly like a board that is fine, until somebody tries to load it.
    my @options = ( '--server', 'Starman', '--workers', 5 );
    push @options, '--enable-ssl', '--ssl-cert', $args{ssl_cert}, '--ssl-key', $args{ssl_key}
      if $args{ssl_cert};

    $runner->parse_options(
        @options, '--host', $args{host}, '--port', $args{port}, '--env', 'deployment',
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
