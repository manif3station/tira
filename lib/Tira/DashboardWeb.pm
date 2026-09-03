package Tira::DashboardWeb;

use strict;
use warnings;

our $VERSION = '1.05';

use Encode qw(decode_utf8 encode_utf8);
use File::Basename ();
use File::Spec ();
use Cpanel::JSON::XS ();
use Dancer2 appname => 'TiraDashboard';

# The View, which this app has never had - no template engine was configured at
# all, so every page came from Perl string concatenation in lib/Tira.pm. The
# views directory resolves from this module rather than from the process's
# working directory: an installed skill is run from anywhere, and a relative
# path would find its templates only when the board was served out of the
# source tree. TKT-703.
set views => File::Spec->catdir(
    File::Basename::dirname( File::Spec->rel2abs(__FILE__) ), 'views' );
set template => 'template_toolkit';

our ( $JOB_RUN, $JOB_CHECK, $JOB_SAVE, $JOB_DELETE, $JOB_STOP, $JOB_START );
our ( $RENDER, $DATA, $MOVE, $DETAIL, $CREATE, $UPDATE, $SEARCH, $COMMENT_ADD, $COMMENT_UPDATE, $COMMENT_REMOVE, $PEOPLE,
      $ATTACHMENT_FETCH, $ATTACHMENT_ADD, $ATTACHMENT_REMOVE, $ATTACHMENT_DISCARD, $CHECKLIST_ADD, $CHECKLIST_UPDATE,
      $REQUIRED_ACTION_UPDATE,
      $LINK_TYPES, $HIERARCHY_LINK, $HIERARCHY_UNLINK, $SUBITEM_LINK, $SUBITEM_UNLINK, $LINK_ADD, $LINK_REMOVE,
      $COLUMNS, $COLUMN_APPLY, $QUESTION_ANSWER, $QUESTION_MARK, $QUESTION_ATTACH,
      $LOGIN_START, $LOGIN_REGISTER, $SESSION_RESUME, $SESSION_PEEK, $SESSION_END, $LOGIN_PAGE,
      $WORK_LOG, $POLICE_LOG, $POLICIES, $POLICY_ADD, $POLICY_REMOVE, $POLICY_DECLINE,
      $TASKLIST, $TASKLIST_ADD, $TASKLIST_UPDATE, $TASKLIST_NEXT, $TASKLIST_SHIFT, $TASKLIST_POP,
      $TASKLIST_UNSHIFT, $TASKLIST_SLICE, $TASKLIST_REMOVE, $TASKLIST_IMPORT, $TASKLIST_PRUNE,
      $TASKLIST_TASK_ATTACH_ADD, $TASKLIST_TASK_ATTACH_DISCARD,
      $TASKLIST_TASK_REF_LINK, $TASKLIST_TASK_REF_UNLINK, $TASKLIST_SESSIONS,
      $JOBS );

our $COOKIE = 'tira_session';

# The board fetches its own routes from its own scripts. A stranger there must
# get a refusal they can react to, not a login page rendered into a card - so
# only the front door serves the page, and everything else answers 401 JSON.
my %PUBLIC = map { $_ => 1 } qw(/login /logout);

# The board polls these on a timer whether anybody is at the keyboard or not.
# Reading a session through one must not push the expiry out, or a tab left
# open overnight would keep itself signed in for ever. /tasklist and
# /tasklist/sessions joined /data here only in TKT-807 - the Task List
# section's own 1-second and 5-second refresh timers (tasklist-editor.js)
# polled far more aggressively than /data ever did, and neither was exempt,
# so a tab with that section visible never actually expired its session.
# /jobs is here for the reason the two tasklist routes are: jobs-editor.js
# refreshes on a timer, and a timer-driven read must not push a session's
# expiry out or a tab left open overnight stays signed in for ever. t/479
# refuses any setInterval-driven GET whose route this does not name, so this
# line is checked rather than remembered. EPC-014, TKT-839.
my %POLLED = ( '/data' => 1, '/tasklist' => 1, '/tasklist/sessions' => 1, '/jobs' => 1,
    '/logs' => 1 );

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
post '/jobs/run' => sub { return _mutation( \$JOB_RUN ) };

# A GET would be wrong here even though nothing is stored: it is a question
# asked while somebody types, and the answer is the ENGINE's refusal rather
# than a second opinion written in JavaScript. Two validators for one format is
# how the engine and the browser ended up disagreeing about attachment content
# types (TKT-713), so the browser asks rather than decides.
post '/jobs/check' => sub { return _mutation( \$JOB_CHECK ) };
post '/jobs/save' => sub { return _mutation( \$JOB_SAVE ) };

# The row's own verbs. Deleting is his complaint 1; stop and start are
# TKT-883's buttons, which needed a stop verb that only arrived with TKT-893.
# POSTs, not GETs: each one changes the board or a process. TKT-892.
post '/jobs/delete' => sub { return _mutation( \$JOB_DELETE ) };
post '/jobs/stop' => sub { return _mutation( \$JOB_STOP ) };
post '/jobs/start' => sub { return _mutation( \$JOB_START ) };

post '/comment/add' => sub { return _mutation( \$COMMENT_ADD ) };
post '/comment/update' => sub { return _mutation( \$COMMENT_UPDATE ) };
post '/comment/remove' => sub { return _mutation( \$COMMENT_REMOVE ) };
post '/attachment/add' => sub { return _mutation( \$ATTACHMENT_ADD ) };
post '/attachment/remove' => sub { return _mutation( \$ATTACHMENT_REMOVE ) };
post '/attachment/discard' => sub { return _mutation( \$ATTACHMENT_DISCARD ) };
post '/checklist/add' => sub { return _mutation( \$CHECKLIST_ADD ) };
post '/checklist/update' => sub { return _mutation( \$CHECKLIST_UPDATE ) };
post '/required-action/update' => sub { return _mutation( \$REQUIRED_ACTION_UPDATE ) };
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

# The board-wide police policy engine (36 rules), separate from a column's
# own required-action template above. TKT-493.
get '/policies' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $POLICIES->() );
};
post '/policy/add' => sub { return _mutation( \$POLICY_ADD ) };
post '/policy/remove' => sub { return _mutation( \$POLICY_REMOVE ) };
post '/policy/decline' => sub { return _mutation( \$POLICY_DECLINE ) };

# TKT-516: the Task List section's own routes, following the exact shape the
# Policies dialog above already uses - one GET for the list, one POST per
# mutation, each a thin pass-through to the same engine methods the CLI uses.
get '/tasklist' => sub {
    my %query;
    for my $pair ( split /&/, request->env->{QUERY_STRING} // '' ) {
        my ( $key, $value ) = split /=/, $pair, 2;
        next if !defined $value;
        $value =~ tr/+/ /;
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $query{$key} = decode_utf8($value);
    }
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $TASKLIST->( \%query ) );
};
get '/jobs' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $JOBS->() );
};

post '/tasklist/add' => sub { return _mutation( \$TASKLIST_ADD ) };
post '/tasklist/update' => sub { return _mutation( \$TASKLIST_UPDATE ) };
post '/tasklist/next' => sub { return _mutation( \$TASKLIST_NEXT ) };
post '/tasklist/shift' => sub { return _mutation( \$TASKLIST_SHIFT ) };
post '/tasklist/pop' => sub { return _mutation( \$TASKLIST_POP ) };
post '/tasklist/unshift' => sub { return _mutation( \$TASKLIST_UNSHIFT ) };
post '/tasklist/slice' => sub { return _mutation( \$TASKLIST_SLICE ) };
post '/tasklist/remove' => sub { return _mutation( \$TASKLIST_REMOVE ) };
post '/tasklist/import' => sub { return _mutation( \$TASKLIST_IMPORT ) };
post '/tasklist/prune' => sub { return _mutation( \$TASKLIST_PRUNE ) };
post '/tasklist/task/attach/add' => sub { return _mutation( \$TASKLIST_TASK_ATTACH_ADD ) };
post '/tasklist/task/attach/discard' => sub { return _mutation( \$TASKLIST_TASK_ATTACH_DISCARD ) };
post '/tasklist/task/ref/link' => sub { return _mutation( \$TASKLIST_TASK_REF_LINK ) };
post '/tasklist/task/ref/unlink' => sub { return _mutation( \$TASKLIST_TASK_REF_UNLINK ) };
# TKT-557: read-only, same shape as GET /tasklist - lets the section discover
# which sessions exist instead of the free-text session box relying on
# somebody already knowing an id, the same gap tira.tasklist.sessions (TKT-541)
# closed for the CLI/agent side.
get '/tasklist/sessions' => sub {
    content_type 'application/json; charset=UTF-8';
    return _response_bytes( $TASKLIST_SESSIONS->() );
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
    [ required_action_update => \$REQUIRED_ACTION_UPDATE, 'required action update provider' ],
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
    [ policies => \$POLICIES, 'policies provider' ],
    [ policy_add => \$POLICY_ADD, 'policy add provider' ],
    [ policy_remove => \$POLICY_REMOVE, 'policy remove provider' ],
    [ policy_decline => \$POLICY_DECLINE, 'policy decline provider' ],
    [ tasklist => \$TASKLIST, 'tasklist provider' ],
    [ tasklist_add => \$TASKLIST_ADD, 'tasklist add provider' ],
    [ tasklist_update => \$TASKLIST_UPDATE, 'tasklist update provider' ],
    [ tasklist_next => \$TASKLIST_NEXT, 'tasklist next provider' ],
    [ tasklist_shift => \$TASKLIST_SHIFT, 'tasklist shift provider' ],
    [ tasklist_pop => \$TASKLIST_POP, 'tasklist pop provider' ],
    [ tasklist_unshift => \$TASKLIST_UNSHIFT, 'tasklist unshift provider' ],
    [ tasklist_slice => \$TASKLIST_SLICE, 'tasklist slice provider' ],
    [ tasklist_remove => \$TASKLIST_REMOVE, 'tasklist remove provider' ],
    [ tasklist_import => \$TASKLIST_IMPORT, 'tasklist import provider' ],
    [ tasklist_prune => \$TASKLIST_PRUNE, 'tasklist prune provider' ],
    [ tasklist_task_attach_add => \$TASKLIST_TASK_ATTACH_ADD, 'tasklist task attach add provider' ],
    [ tasklist_task_attach_discard => \$TASKLIST_TASK_ATTACH_DISCARD, 'tasklist task attach discard provider' ],
    [ tasklist_task_ref_link => \$TASKLIST_TASK_REF_LINK, 'tasklist task ref link provider' ],
    [ tasklist_task_ref_unlink => \$TASKLIST_TASK_REF_UNLINK, 'tasklist task ref unlink provider' ],
    [ tasklist_sessions => \$TASKLIST_SESSIONS, 'tasklist sessions provider' ],
    [ jobs => \$JOBS, 'repeated jobs provider' ],

    # His msg 6484 - a play button that runs a job "anytime bypass the
    # schedule" - and msg 6485, a modal that will not let a malformed crontab
    # be saved. Two providers rather than one compound verb, which is the
    # convention every other operation here already follows. EPC-014, TKT-843.
    [ job_run => \$JOB_RUN, 'job run provider' ],
    [ job_check => \$JOB_CHECK, 'job schedule check provider' ],
    [ job_save => \$JOB_SAVE, 'job save provider' ],

    # His three complaints of 2026-09-03 - a job card cannot be deleted, cannot
    # be edited, and command-or-message cannot be chosen. The verbs all existed;
    # the row had no way to reach them. TKT-892, absorbing TKT-883 and TKT-889.
    [ job_delete => \$JOB_DELETE, 'job delete provider' ],
    [ job_stop => \$JOB_STOP, 'job stop provider' ],
    [ job_start => \$JOB_START, 'job start provider' ],
);

# What this server has answered, for the panel his --show-logs asks for.
#
# TKT-852. He asked for it after the dashboard would not load and nothing could
# say whether requests were arriving at all: `tira.dashboard -o browser` starts
# a server and then says nothing about what it serves.
#
# A FIXED RING, NOT A TIME WINDOW, decided as CHK-001 before this was written.
# A window bounds memory only if a request rate is assumed, and this panel is
# read precisely when the rate is unusual. 200 entries is about twenty-five
# minutes of idle history, since the page already polls four routes every
# thirty seconds - long enough to see a pattern, small enough that a dashboard
# left open overnight holds kilobytes rather than a day of polling.
#
# RECORDED WITH THE STATUS, which is the half that says what HAPPENED rather
# than what was attempted. A request that was refused is the case he was
# actually diagnosing, and it looks identical to a successful one until the
# status is there.
our $SHOW_LOGS = 0;
my $REQUEST_LOG_LIMIT = 200;
my @REQUEST_LOG;

sub _record_request {
    my ( $path, $status ) = @_;
    push @REQUEST_LOG, { path => $path, status => $status };
    shift @REQUEST_LOG while @REQUEST_LOG > $REQUEST_LOG_LIMIT;
    return scalar @REQUEST_LOG;
}

# A copy, so a caller cannot reach in and change the server's own record - the
# same reason Tira::CLI::Options::misleading_for hands out a deep copy.
sub _request_log {
    return [ map { { %{$_} } } @REQUEST_LOG ];
}

sub _request_log_reset {
    @REQUEST_LOG = ();
    return 1;
}

# Recorded here rather than in the `before` hook, and the difference matters:
# `before` returns early for public paths and halts for unauthorised ones, so
# the status does not exist yet there. A request that was REFUSED is the case he
# was diagnosing, and in `before` it would have been recorded as though it had
# merely arrived.
hook after => sub {
    my ($response) = @_;
    return if !$SHOW_LOGS;

    # THE PANEL DOES NOT RECORD ITSELF. logs-panel.js polls /logs every five
    # seconds, which is twelve requests a minute on an otherwise idle board -
    # more than the four polled board routes produce between them. Recording
    # those would fill the ring with the act of looking, and the requests
    # somebody opened the panel to see would fall off the end within minutes.
    # Raised in review, where the retention arithmetic gave it away.
    return if $response && request->path eq '/logs';

    _record_request( request->path, $response->status );
    return;
};

get '/logs' => sub {
    content_type 'application/json; charset=UTF-8';

    # Absent rather than empty when the flag was not given. An empty list would
    # tell a reader the server had answered nothing, which is a different claim
    # from "this board is not keeping a record".
    if ( !$SHOW_LOGS ) {
        status 404;
        return _response_bytes( Tira::json_object()->encode(
            { error => 'This board was not started with --show-logs' } ) );
    }
    return _response_bytes( Tira::json_object()->encode( _request_log() ) );
};

sub build_psgi_app {
    my ( $class, %args ) = @_;
    for my $provider (@PROVIDERS) {
        my ( $name, $slot, $label ) = @{$provider};
        die "Missing dashboard $label\n" if ref( $args{$name} ) ne 'CODE';
        ${$slot} = $args{$name};
    }
    return __PACKAGE__->to_app;
}

# The board is served from a file, not from a closure built here.
#
# A coderef built in this process is in memory before Starman forks, so its
# workers inherit it and a HUP reloads nothing - which is why a served board
# went on running old code after an upgrade, reported by the owner on
# 2026-08-15. A path is loaded by each worker instead, so a HUP re-forks
# workers that read the modules from disk again while the master keeps the
# listening socket.
#
# Proved before choosing it: a two-worker Starman serving a .psgi that read a
# version from a file answered "version one", the file was changed and the
# master sent HUP, and it answered "version two". Server::Starter is the
# documented answer for an application that must be preloaded, and is not
# needed once nothing is.
#
# dashboard.psgi has shipped since it was written and nothing referenced it. It
# builds the same application from TIRA_DASHBOARD_ROOT with the same providers
# the CLI uses, which is what makes this wiring rather than construction.
# Where the file lives, relative to this module rather than to whatever
# directory the board was launched from - a served board is started from
# anywhere and must find its own application.
sub _psgi_path {
    my ($class) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe module path\n";
    my $root = File::Spec->rel2abs(
        File::Spec->catdir( File::Basename::dirname($1), File::Spec->updir, File::Spec->updir ) );
    my $psgi = File::Spec->catfile( $root, 'dashboard.psgi' );
    die "The dashboard application is missing at $psgi\n" if !-f $psgi;
    return $psgi;
}

sub serve {
    my ( $class, %args ) = @_;

    # Which board, asked first.
    #
    # The workers load the file themselves and cannot be handed a closure over
    # it, so the board travels in the environment - and dashboard.psgi reads
    # TIRA_DASHBOARD_ROOT and dies without it. Serving without one would start
    # workers that die on load, in a child whose error stream nobody is
    # reading, which is the worst place for a message to go.
    #
    # Before the providers are checked, because "which board" is the more basic
    # question: a caller who forgot it should hear that rather than a complaint
    # about a renderer they never mentioned. Found by writing the test - the
    # first version asked in the other order and said the wrong thing.
    my $project = $args{project};
    die "Serving a board needs to know which one, already resolved\n"
      if !defined $project || $project eq '';

    # Resolved here, where it can be, rather than in each worker, where it
    # cannot. The workers start fresh and read TIRA_DASHBOARD_ROOT, so whatever
    # goes in has to be something a process with no other context can open - and
    # the dispatcher passes a project NAME. The owner's board bound its port and
    # then answered every request with "Cannot resolve project path 'tira'",
    # because a name that resolves in the process asked to serve need not
    # resolve in the processes doing the serving.
    #
    # Refused here too, for the same reason the providers are: a board nobody
    # can find should be said where the caller is looking, not inside a worker
    # whose error stream nobody is reading.
    # Resolved by the caller, which is the only party that can. A project may be
    # named rather than pathed - that is deliberate, so an agent reading the
    # manual never learns where the board actually sits - and the name is
    # resolved through a path resolver the CLI installs from the dashboard's own
    # registry. A Tira built here would not have one, and neither does the one
    # dashboard.psgi builds: that is exactly why the workers could not resolve
    # 'tira' and answered every request with "Cannot resolve project path".
    # Says nothing about what it was given or what it wanted. A refusal that
    # quotes the value teaches whoever reads it how boards are referred to here,
    # and that is the one thing this is all arranged to avoid.
    die "Serving a board needs to know which one, already resolved\n"
      if !File::Spec->file_name_is_absolute($project);

    # The providers are still validated here, so that a caller who hands in its
    # own - every test that stubs one - still gets what it asked for, and so a
    # missing provider is refused where somebody sees it rather than inside a
    # worker.
    $class->build_psgi_app( map { $_->[0] => $args{ $_->[0] } } @PROVIDERS );

    local $ENV{TIRA_DASHBOARD_ROOT} = $project;
    local $ENV{TIRA_DASHBOARD_TYPE} = $args{type} // '';
    local $ENV{TIRA_DASHBOARD_TITLE} = $args{with_title} ? '1' : '0';

    my $app = $class->_psgi_path;

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
dialog can surface the engine's message. GET /tasklist, GET /tasklist/sessions
(TKT-557), and the fourteen POST /tasklist/* routes give the Task List
section full CLI parity with C<tira.tasklist.*>, mutations answered the
same validated-422 way as every other route. C<serve> runs the PSGI
application through Plack's bundled
standalone server at a validated CLI bind address.

Since 4.70 the application configures a Template Toolkit engine, which it never
had before - the board's markup used to be built entirely by string
concatenation in L<Tira>. C<views> is resolved from this module's own directory
via C<__FILE__> rather than from the process's working directory, because an
installed skill is run from anywhere and a relative path would find the
templates only when the board happened to be served out of the source tree. The
templates and the stylesheet and scripts beside them are inlined into the page
at render, never linked: the board answers its own routes constantly, but it
loads nothing from another host, and a C<< <link> >> or C<< <script src> >>
would be exactly that. TKT-703.

=head1 METHODS

=head2 build_psgi_app

Accepts every provider coderef this module's routes call through - every
name is required, and a missing one is refused by name rather than
discovered at request time. Grouped by the routes they answer (TKT-558,
replacing a list of 12 that had not grown since long before most of
these existed):

=over 4

=item * Board and card: render, data, move, detail, create, search, columns

=item * Comments: comment_add, comment_update, comment_remove

=item * Record fields: update, question_answer, question_mark, question_attach, column_apply

=item * Attachments: attachment_fetch, attachment_add, attachment_remove, attachment_discard

=item * Checklists and required actions: checklist_add, checklist_update, required_action_update

=item * Hierarchy and links: link_types, hierarchy_link, hierarchy_unlink, subitem_link, subitem_unlink, link_add, link_remove

=item * Login and session: login_start, login_register, session_resume, session_peek, session_end, login_page

=item * Work log and police: work_log, police_log, policies, policy_add, policy_remove, policy_decline

=item * People: people

=item * Repeated jobs: jobs, job_run, job_check, job_save, job_delete, job_stop, job_start

The C</logs> route takes no provider: the record lives in this module, written
by an C<after> hook and read back by C<_request_log>. It is served only when
C<$SHOW_LOGS> is set, which C<tira.dashboard --show-logs> does. The C<after>
hook rather than C<before> is deliberate - C<before> returns early for public
paths and halts for unauthorised ones, so the status does not exist there yet,
and a B<refused> request is the case the flag was asked for. EPC-007, TKT-852.

C<job_run> answers the play button - it runs one job now whatever its
schedule says, and starts a C<monitor> row rather than firing it, since a
monitor has no schedule to bypass. C<job_check> answers the editor modal
while somebody types, returning the B<engine's> own refusal for a
malformed crontab rather than a second opinion written in JavaScript -
two validators for one format is how the engine and the browser came to
disagree about attachment content types (TKT-713).

C<job_delete>, C<job_stop> and C<job_start> are the row's own verbs, added
for his three complaints of 2026-09-03 - a job card could not be deleted,
could not be edited, and command-or-message could not be chosen. Each verb
already existed on the board; none of them had a surface. C<job_delete>
lets the engine's refusal travel to the page rather than catching it: a
B<running> monitor is refused with words that name C<tira.job.stop>,
because removing the record while the process runs leaves a pid nothing
points at. C<job_stop> goes through the CLI dispatcher rather than the
engine sub, since the engine clears the record and the CLI signals, in
that order - calling the engine alone would clear the record and signal
nothing, which is the board-says-stopped-process-still-running state the
card exists to remove. C<job_start> uses the same C<run_now> executor the
play button does. EPC-014, TKT-892.

=item * Task List: tasklist, tasklist_add, tasklist_update, tasklist_next, tasklist_shift, tasklist_pop, tasklist_unshift, tasklist_slice, tasklist_remove, tasklist_import, tasklist_prune, tasklist_task_attach_add, tasklist_task_attach_discard, tasklist_task_ref_link, tasklist_task_ref_unlink, tasklist_sessions

=back

Returns the Dancer2 PSGI application. The attachment fetch provider
returns a typed payload that the GET /attachment route streams with its
content type and disposition; unknown attachments answer 404.

=head2 serve

Runs the application using the supplied C<host>, C<port>, and provider values.

=cut
