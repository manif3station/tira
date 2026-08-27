package Tira::CLI;

use strict;
use warnings;

use Encode qw(decode encode_utf8 FB_CROAK LEAVE_SRC);
use Cwd qw(abs_path cwd);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use Cpanel::JSON::XS ();
use Tira;

# PATH separators, executable extensions and the absence of an execute bit are
# all facts about the platform being described rather than the one this is
# running on, so they hang off a flag a test can set.
our $WINDOWS = $^O eq 'MSWin32' ? 1 : 0;

# Where one option names the job another option does. Refused rather than
# silently discarded: a wrong flag that parses looks accepted, and a command
# that reports success without doing anything is worse than one that fails.
my %MISLEADING_OPTIONS = (
    'assign.set'    => [ [ 'assignee', 'person' ] ],
    'assign.add'    => [ [ 'assignee', 'person' ] ],
    'assign.remove' => [ [ 'assignee', 'person' ] ],

    # Evidence carries a summary, a link and an attachment. --details is
    # gate.add's, and evidence.add accepted it and threw it away: the entry it
    # printed looked complete because the summary was there, so nothing said
    # that half of what was typed had gone nowhere. A night of evidence on this
    # board lost its reasoning that way.
    'evidence.add'  => [ [ 'details', 'summary' ] ],
);

# An option the shared parser knows and a few commands read.
#
# --field names the field tira.history reports on, and the fields tira.search
# and tira.replace work over. Every other command took it, stored it and
# dropped it: a record update given --field exited zero and printed the card
# back, which reads as confirmation because the card is right there. An hour of
# this project's own writing went that way - a card raised from a bug hunt,
# filled in with six of them, and still a title when the push gate refused the
# release for it.
#
# Declared rather than derived, for the same reason %MISLEADING_OPTIONS is:
# there is no per-command list of the options each command uses, and inventing
# one would refuse things that work today. What is declared is an option whose
# readers are known.
#
# The readers were counted from the engine rather than from the CLI. Reading
# only the CLI found one - history.list, which names the option explicitly -
# and missed search and replace, which receive it in the arguments every
# command passes through. A refusal written from that count would have broken
# two working commands.
my %OPTION_READ_BY = (
    # The gate a move would not set. Accepted, dropped, exit 0, whole card
    # printed - which reads as confirmation because the card is right there.
    # It costs more than --field did: a board whose rules require the gate to
    # move with every transition makes "move and set the gate" the most natural
    # thing to type, so the correct action was being expressed in one command
    # and silently half-done. Refused rather than made to work, because that is
    # reversible and quietly doing half of a transition is not. TKT-281.
    sdlc_gate => {
        flag     => 'sdlc-gate',
        commands => qr/\Arecord\.(?:create|update)\z/,
        instead  => 'tira.<type>.update --sdlc-gate, which is the command that sets it',
    },

    # The reason a discard would not record. Accepted, dropped, exit 0, whole
    # card printed - and it happened twice in ten minutes on this project's own
    # board, with discard-unexplained firing both times.
    #
    # It costs more than --sdlc-gate did. The dropped value is the reason a card
    # was set aside, and discard-unexplained exists precisely to require that
    # reason, so the option that looks like the way to satisfy the rule is the
    # one way that cannot. TKT-302.
    comment => {
        flag     => 'comment',
        # The commands that DO read it, which is what this table lists - the
        # first draft named record.discard here and so declared the broken
        # command to be the one that works.
        commands => qr/\A(?:comment\.|attachment\.discard\z)/,
        instead  => 'tira.comment.add --ref REF --text TEXT, which is the command that records a reason',

        # attachment.discard reads --comment as an identifier - which
        # comment to detach the attachment from - not a reason, so of the
        # exempted commands it is the one where a caller could plausibly
        # mean the wrong thing. A value that cannot be a comment id is
        # refused the same way, rather than accepted and quoted back as a
        # missing identifier: measured live, 'tira.attachment.discard
        # --comment "Set aside because it was the wrong file"' answered
        # "Comment 'Set aside...' not found" and recorded nothing. TKT-373.
        shape_checked_on => qr/\Aattachment\.discard\z/,
        shape            => qr/\ACMT-\d+\z/,
    },

    fields => {
        flag     => 'field',
        commands => qr/\A(?:history\.list|search|replace)\z/,
        instead  => 'the options that set a field - --key-detail, --deliverable,'
          . ' --acceptance, --test-step and the rest the command reference lists',
    },

    # A link an evidence entry carries. Read in exactly one place in the whole
    # engine, evidence_add - so release.record (TKT-345) accepted --uri,
    # dropped it, and exited 0 with an evidence entry that looked complete
    # because the summary was right there. Same shape as sdlc_gate and
    # comment above: TKT-431.
    uri => {
        flag     => 'uri',
        commands => qr/\Aevidence\.add\z/,
        instead  => 'tira.evidence.add --ref REF --summary TEXT --uri TEXT, which is the command that reads it',
    },

    # Whether this board is worked by one agent or a chain of them. Accepted,
    # dropped, exit 0, whole project printed - the same shape as sdlc_gate and
    # comment above, on the project rather than a card. Several rules mean
    # different things between the two modes, so a board that believes it
    # declared chain and is still single gets different behaviour from every
    # one of them, with nothing to say why. TKT-382.
    mode => {
        flag     => 'mode',
        # project.new and onboard read it too - both write it themselves,
        # straight after the project exists, the same way this table's other
        # entries name every command that genuinely reads an option rather
        # than only the one whose name matches it.
        commands => qr/\A(?:project\.mode|project\.new|onboard)\z/,
        instead  => 'tira.project.mode --mode VALUE, which is the command that sets it',
    },
);

sub _refuse_unread_options {
    my ( $command, $option ) = @_;
    for my $name ( sort keys %OPTION_READ_BY ) {
        my $rule = $OPTION_READ_BY{$name};
        my $given = $option->{$name};
        next if !defined $given;
        next if ref $given eq 'ARRAY' && !@{$given};
        if ( $command =~ $rule->{commands} ) {
            next
              if !$rule->{shape_checked_on}
              || $command !~ $rule->{shape_checked_on}
              || $given =~ $rule->{shape};
        }
        die "$command does not act on --$rule->{flag}. Use $rule->{instead}.\n";
    }

    # And the rest of the surface, derived rather than listed. The table above
    # grew one entry per incident - TKT-281, TKT-302 - and each entry covered
    # the option somebody had already been bitten by. These two lists come from
    # the engine, so a field added to record_update is refused on the commands
    # that will not write it without anybody remembering to add it here.
    #
    # Which commands read what was measured rather than assumed, and the obvious
    # rule turned out to be wrong: record.create reads all eighteen append
    # fields and loses none, so "only update writes fields" would have broken
    # every card this project raises. Only the replacements are update-only.
    # Scoped to the record verbs that move a card about without writing its
    # fields, rather than to every command in the tool. The first draft applied
    # everywhere and broke the browser dashboard: --title is a card field on
    # create and update AND a display flag on tira.dashboard, which shows titles
    # beside references. A guard wide enough to catch every drop is also wide
    # enough to refuse commands that read the same word for something else.
    my %guarded = map { $_ => 1 }
      qw(record.move record.discard record.restore record.clone);
    my %flag_of = (
        problem_or_feature => 'problem', solution_needed => 'solution-needed',
        sdlc_gate => 'sdlc-gate', fix_version => 'fix-version',
        agent_session => 'agent-session', due_date => 'due-date',
        start_date => 'start-date', labels => 'label',
        affects_versions => 'affects-version', key_details => 'key-detail',
        deliverables => 'deliverable', test_steps => 'test-step',
        scope_in => 'scope-in', scope_out => 'scope-out',
    );
    for my $field ( @{ Tira::card_fields() } ) {
        next if !$guarded{$command};

        # The one option clone genuinely reads. Kept by name because a clone
        # without a title is refused for the title, and a first probe of this
        # read that refusal as a refusal of the option beside it.
        next if $command eq 'record.clone' && $field eq 'title';

        my $given = $option->{$field};
        next if !defined $given;
        next if ref $given eq 'ARRAY' && !@{$given};
        my $flag = $flag_of{$field} // $field;
        $flag =~ tr/_/-/;
        die "$command does not act on --$flag. Use tira.<type>.update --$flag,"
          . " which is the command that writes it.\n";
    }
    for my $field ( @{ Tira::card_field_replacements() } ) {
        # The replacements are update-only, so create is guarded here and not
        # above: it reads all eighteen append fields and loses none, measured.
        next if $command !~ /\Arecord\.(?:create|move|discard|restore|clone)\z/;
        next if $command eq 'record.update';
        my $given = $option->{ 'set_' . ( $field =~ s/_replace\z//r ) };
        next if !defined $given;
        ( my $flag = 'set-' . ( $field =~ s/_replace\z//r ) ) =~ tr/_/-/;
        die "$command does not act on --$flag. Use tira.<type>.update --$flag,"
          . " which is the command that replaces it.\n";
    }
    return;
}

# The process that set a served board up, recorded before the server forks.
# Outside a served board it is simply this process, so a plain command asking
# the question gets the honest answer rather than a special case.
our $SERVING_PID;
sub _serving_pid { return $SERVING_PID // $$ }

sub run {
    my ( $class, %args ) = @_;

    # Tira encodes its output to UTF-8 bytes and prints them. Perl puts a
    # text-mode layer on standard output on Windows, which rewrites every
    # newline on the way out, so the bytes that left the process were not the
    # bytes Tira produced - and Tira compares output bytes in its own cache.
    # Taking the layer off makes the output the same everywhere.
    binmode $_, ':raw' for ( \*STDOUT, \*STDERR );

    my $command = $args{command} // '';
    my $type = $args{type};
    my $argv = $args{argv} || [];
    my $tira = $args{tira} || Tira->new( path_resolver => _dd_path_resolver() );
    my $browser_server = $args{browser_server} || \&_serve_browser;
    my $onboard_browser_server = $args{onboard_browser_server} || \&_serve_onboard_browser;
    my $restarter = $args{restarter} || \&_restart_into;
    my $guided_input = $args{input};
    my %option = ( output => 'toon' );
    our @RESTART_ARGV = @{$argv};
    my $environment_project;
    my $decoded = eval {
        for my $argument ( @{$argv} ) {
            $argument = decode( 'UTF-8', $argument, FB_CROAK ) if !utf8::is_utf8($argument);
        }
        # LEAVE_SRC, because decode consumes what it is given. Reading the
        # environment used to empty it, and it did not matter while a flag
        # could carry the board instead: the first command in a process took
        # the value and every command after it in that process saw an empty
        # string. With one way to name a board there is nothing to fall back
        # on, and a suite that runs many commands in one process finds it at
        # once - which is how this was found. TKT-250.
        if ( defined $ENV{TIRA_HOME} ) {
            $environment_project = utf8::is_utf8( $ENV{TIRA_HOME} )
              ? $ENV{TIRA_HOME}
              : decode( 'UTF-8', $ENV{TIRA_HOME}, FB_CROAK | LEAVE_SRC );
        }
        1;
    };
    return _error( $tira, 'toon', $@ || 'Invalid UTF-8 command-line input' ) if !$decoded;
    my @spec = (
        'name=s' => \$option{name}, 'dir=s' => \$option{dir}, 'title:s' => \$option{title},
        'description=s' => \$option{description},
        'output|o=s' => \$option{output}, 'help' => \$option{help},
        'id=s' => \$option{id}, 'email=s' => \$option{email},
        'message=s' => \$option{message}, 'all' => \$option{all},
        'columns-json=s' => \$option{columns_json},
        'nested' => \$option{nested},
        'mark=s' => \$option{mark},
        'reason=s' => \$option{reason}, 'option=s@' => \$option{options},
        'voice=s' => \$option{voice}, 'remove' => \$option{remove},
        'question=s@' => \$option{questions}, 'filename=s' => \$option{filename},

        # Both of these were documented and neither could be passed: the
        # dashboard read with_questions from an option nothing ever set, and
        # card-sandbox-missing needs a sandbox the command line could not
        # take. Found by widening the documentation check to read the argument
        # tables, which is where almost every flag here is written down.
        'with-questions!' => \$option{with_questions},
        'no-session-expire' => \$option{no_session_expire},
        'ssl' => \$option{ssl},
        'sandbox=s' => \$option{sandbox},
        'repo=s' => \$option{repo}, 'repair!' => \$option{repair},
        'collector=s' => \$option{collector}, 'agent=s' => \$option{agent},
        'session=s' => \$option{session}, 'heartbeat=s' => \$option{heartbeat},
        'all-sessions' => \$option{all_sessions},
        'unlinked' => \$option{unlinked},
        'outward=s' => \$option{outward}, 'inward=s' => \$option{inward},
        'type=s' => \$option{type}, 'label=s@' => \$option{labels},
        'after=s' => \$option{after}, 'before=s' => \$option{before},
        'new-name=s' => \$option{new_name}, 'prefix=s' => \$option{prefix},
        'digits=i' => \$option{digits}, 'ref=s@' => \$option{ref_list},
        'refs=s' => \$option{refs},
        'column=s' => \$option{column}, 'parent=s' => \$option{parent},
        'child=s' => \$option{child},
        'text=s' => \$option{text}, 'problem|problem-or-feature=s' => \$option{problem_or_feature},
        'solution-needed=s' => \$option{solution_needed}, 'source=s' => \$option{source},
        'from=s' => \$option{from}, 'to=s' => \$option{to},
        'chat=s' => \$option{chat},
        'author=s' => \$option{author}, 'file=s@' => \$option{files},
        'format=s' => \$option{format}, 'comment=s' => \$option{comment},
        'sha=s' => \$option{sha}, 'extension=s' => \$option{extension},
        'summary=s' => \$option{summary}, 'uri=s' => \$option{uri},
        'gate=s' => \$option{gate}, 'result=s' => \$option{result},
        'details=s' => \$option{details}, 'evidence=s' => \$option{evidence},
        'item=s' => \$option{item}, 'status=s' => \$option{status},
        'peek' => \$option{peek},
        'command=s@' => \$option{command}, 'proof=s@' => \$option{proof},
        'field=s@' => \$option{fields}, 'pattern=s' => \$option{pattern},
        'fields=s@' => \$option{field_selection},
        'exclude-fields=s@' => \$option{exclude_fields},
        'include-empty' => \$option{include_empty},
        'since=s' => \$option{since},
        'if-changed=s' => \$option{if_changed},
        'count' => \$option{count}, 'refs-only' => \$option{refs_only},
        'tasklist' => \$option{tasklist},
        'brief' => \$option{brief}, 'truncate=i' => \$option{truncate},
        'last=i' => \$option{last}, 'first=i' => \$option{first},
        'position=i' => \$option{position},
        'attach=s@' => \$option{attach}, 'sort=s' => \$option{sort},
        'meta-only' => \$option{meta_only},
        'where=s@' => \$option{where},
        'members=s@' => \$option{members}, 'columns=s@' => \$option{columns},
        'listen=s' => \$option{listen},
        'password=s' => \$option{password},
        'rule=s' => \$option{rule}, 'action=s' => \$option{action},
        'enter=s' => \$option{enter}, 'before-column=s' => \$option{before_column},
        'age=s' => \$option{age}, 'read-age=s' => \$option{read_age},
        'max=i' => \$option{max}, 'require=s' => \$option{require},
        'once' => \$option{once}, 'interval=i' => \$option{interval},
        'fresh' => \$option{fresh},

        # An exit status a scheduled job can act on, and a work list rather
        # than a data dump. Both opt-in: a command that starts exiting
        # non-zero breaks every script running it today, and the precedent for
        # a status carrying an answer is --if-changed. TKT-279.
        # Named by-rule rather than summary: --summary already belongs to
        # evidence.add, and Getopt::Long answers a duplicate specification with
        # a warning printed into the output, which turned a JSON payload into
        # something no caller could parse. The suite said so twice at once.
        'exit-nonzero-if-any' => \$option{exit_nonzero_if_any},
        'by-rule' => \$option{by_rule},

        # Agreeing to lose work. Spelled out rather than a single letter,
        # because the one command that can destroy a board should not be
        # reachable by a slip of the hand.
        'yes' => \$option{yes},
        'claiming-schema=i' => \$option{claiming_schema},
        'seconds=i' => \$option{seconds},
        'pid=i' => \$option{pid},
        'on-column=s' => \$option{on_column},
        'role=s@' => \$option{roles}, 'remove-role=s@' => \$option{remove_roles},
        'gate-name=s@' => \$option{gate_names},
        'require-link=s' => \$option{require_link}, 'link-to=s' => \$option{link_to},
        'notify' => \$option{notify},
        'enter-role=s' => \$option{enter_role}, 'before-role=s' => \$option{before_role},

        # The third of the three the command reference offers. It was
        # documented beside the other two and never in this list, so
        # policy.add answered "Unknown option: column-role" and refused the
        # whole command - while the engine declared the field and evaluated it
        # in the same loop as its neighbours. Only the way to give it a value
        # was missing. TKT-221.
        'column-role=s' => \$option{column_role},
        'rounds=i' => \$option{rounds},
        'store=s' => \$option{store},
        'dashboard-host=s' => \$option{dashboard_host},
        'dashboard-port=s' => \$option{dashboard_port},
        'sow-columns=s@' => \$option{sow_columns}, 'epic-columns=s@' => \$option{epic_columns},
        'ticket-columns=s@' => \$option{ticket_columns},
        'sow-prefix=s' => \$option{sow_prefix}, 'epic-prefix=s' => \$option{epic_prefix},
        'ticket-prefix=s' => \$option{ticket_prefix},
        'snapshot=s' => \$option{snapshot},
        'older-than=s' => \$option{older_than},
        'notify-after=s' => \$option{notify_after}, 'mode=s' => \$option{mode},
        'said=s' => \$option{said}, 'heard=s' => \$option{heard},
        'agent-session=s' => \$option{agent_session},
        'watch!' => \$option{watched}, 'terminal!' => \$option{terminal}, 'stale' => \$option{stale},
        'queue!' => \$option{queue},
        'required-action=s@' => \$option{required_action},
        'next=s@' => \$option{next},
        'with-level' => \$option{with_level},
        'cache-ttl=i' => \$option{cache_ttl}, 'no-cache' => \$option{no_cache},
        'with=s' => \$option{with}, 'note=s' => \$option{note},
        'reporter=s' => \$option{reporter}, 'due-date=s' => \$option{due_date},
        'start-date=s' => \$option{start_date}, 'sdlc-gate=s' => \$option{sdlc_gate},
        'lifecycle=s' => \$option{lifecycle}, 'priority=s' => \$option{priority},
        'fix-version=s' => \$option{fix_version},
        'repair-columns' => \$option{repair_columns}, 'apply' => \$option{apply},
        'recursive' => \$option{recursive}, 'include-deleted' => \$option{include_deleted},
        'include-discard' => \$option{include_discard},
        'full' => \$option{full}, 'dry-run' => \$option{dry_run},
        'key-detail=s@' => \$option{key_details}, 'deliverable=s@' => \$option{deliverables},
        'scope-in=s@' => \$option{scope_in}, 'scope-out=s@' => \$option{scope_out},
        'exempt-required=s@' => \$option{required_exempt}, 'exempt-reason=s@' => \$option{exempt_reason},
        'acceptance|acceptance-criteria=s@' => \$option{acceptance}, 'test-step=s@' => \$option{test_steps},
        'bdd=s@' => \$option{bdd}, 'atdd=s@' => \$option{atdd},
        'assignee=s' => \$option{assignee}, 'person=s@' => \$option{people},
        'attach=s@' => \$option{attach},
        'affects-version=s@' => \$option{affects_versions},
        'set-key-details=s' => \$option{set_key_details},
        'set-deliverables=s' => \$option{set_deliverables},
        'set-acceptance|set-acceptance-criteria=s' => \$option{set_acceptance},
        'set-test-steps=s' => \$option{set_test_steps},
        'set-bdd=s' => \$option{set_bdd}, 'set-atdd=s' => \$option{set_atdd},
        'set-labels=s' => \$option{set_labels},
        'set-affects-versions=s' => \$option{set_affects_versions},
        'set-scope-in=s' => \$option{set_scope_in},
        'set-scope-out=s' => \$option{set_scope_out},
    );

    # TKT-389: a single-valued option given twice on the same command line
    # silently kept the last value and dropped the rest, with exit 0 - for
    # --priority in particular a card meant to be P5 lands as P1, and the
    # surviving value is what the output prints, so it reads as success.
    # Guarded once here, generically, over every spec that takes a value and
    # is not itself repeatable (no '@'): the 94 against 25 the ticket counted
    # would otherwise have been 94 places to keep in step by hand.
    my @duplicate_option;
    my %already_given;
    for ( my $i = 0; $i < @spec; $i += 2 ) {
        my $spec_str = $spec[$i];
        next if $spec_str =~ /\@/;
        next if $spec_str !~ /[=:]/;
        ( my $primary = $spec_str ) =~ s/[|=:!].*//;
        my $target = $spec[ $i + 1 ];
        $spec[ $i + 1 ] = sub {
            my ( undef, $value ) = @_;

            # A default such as output => 'toon' is set in %option before
            # parsing even starts, so "the target already holds a value" is
            # not the same question as "this flag was already given" - the
            # first --output on a command line must not be read as a second
            # occurrence of one that was never actually typed.
            push @duplicate_option,
              "--$primary was given more than once ('" . $$target . "' and '$value')"
              if $already_given{$primary}++;
            $$target = $value;
        };
    }
    # An unknown COMMAND already gets "Did you mean" - the dispatcher this
    # project sits inside supplies that. An unknown OPTION got only "Unknown
    # option: X" straight from Getopt::Long, discarded into a generic
    # "Invalid command-line options" with nothing suggested - the same help a
    # command typo gets, missing for the far more common typo of a flag.
    # TKT-298: one bad option name discarded a whole update carrying twenty
    # composed fields, and finding which flag was wrong cost writing a probe
    # value into a live card. Getopt::Long only warns to STDERR, so its own
    # unknown-option text is captured here rather than re-derived.
    my $unknown_option_warning = '';
    my $parsed = do {
        local $SIG{__WARN__} = sub { $unknown_option_warning .= $_[0] };
        GetOptionsFromArray( $argv, @spec );
    };
    return _error( $tira, $option{output},
        join( '; ', @duplicate_option )
          . " - repeating a single-valued option drops every value but the last silently. Give it once.\n" )
      if @duplicate_option;
    if ( !$parsed || @{$argv} ) {
        my @unknown = $unknown_option_warning =~ /Unknown option:\s*(\S+)/g;
        return _error( $tira, $option{output}, _unknown_option_message( \@unknown, \@spec ) )
          if @unknown;

        # Any other Getopt::Long complaint - a value missing, one of the
        # wrong type - used to reach STDERR unfiltered, since nothing
        # installed a $SIG{__WARN__} before this. Capturing the unknown-
        # option case above must not silence these too; printed here so the
        # diagnostic Getopt::Long already wrote is not simply discarded.
        print {*STDERR} _utf8_bytes($unknown_option_warning) if $unknown_option_warning ne '';
        return _error( $tira, $option{output}, 'Invalid command-line options' );
    }

    # --file is a list only where a batch makes sense, and one file everywhere
    # else. Nine commands read it - attachment, question voice and answer, bulk
    # import, comment add and update among them - so handing eight of them an
    # arrayref and fixing each with ->[0] would be eight places to drift, which
    # is the fault TKT-389 is about. Collapsed once, here.
    #
    # Giving it twice used to keep the last and discard the rest with exit 0.
    # That is one of the single-valued flags TKT-389 counts, closed here because
    # this card had to touch the option anyway; the rest stay on that card.
    # TKT-338.
    if ( $option{files} ) {
        return _error( $tira, $option{output},
            "Only attachment.add, tasklist.task.attach.add and tasklist.task.attach.discard take more than one --file\n" )
          if @{ $option{files} } > 1
          && $command !~ /\A(?:attachment\.add|tasklist\.task\.attach\.(?:add|discard))\z/;
        $option{file} = $option{files}[0];
    }
    $option{ref} = $option{ref_list}[-1] if $option{ref_list};
    $option{$_} = _expand_home( $option{$_} ) for grep { defined $option{$_} } qw(dir project);

    if ( $option{help} || $command eq 'policies' ) {
        print $command eq 'policies' ? _policy_help() : _usage( $command, $type );
        return 0;
    }

    return _error( $tira, 'toon', "Unsupported output format '$option{output}' - "
        . '--output/-o names the response FORMAT (toon, json or human) on every command here, '
        . 'never a destination path. attachment.get always writes its raw content to stdout, '
        . "so save it with shell redirection: > FILE" )
      if $command eq 'attachment.get' && $option{output} !~ /\A(?:toon|json|human)\z/;
    return _error( $tira, 'toon', 'Table output is available only for dashboard commands' )
      if $option{output} eq 'table' && $command !~ /\Adashboard(?:\.(?:sow|epic|ticket))?\z/;
    return _error( $tira, 'toon', 'Browser output is available only for dashboard and onboard commands' )
      if $option{output} =~ /\Abrowser(?:=|\z)/
      && $command !~ /\A(?:dashboard(?:\.(?:sow|epic|ticket))?|onboard)\z/;

    # One way to say which board: the environment, holding a name the machine
    # resolves. There were three - a flag, this, and the working directory -
    # and three ways to say one thing is three behaviours to keep in agreement.
    # They had already stopped agreeing. The internal name stays because the
    # engine is told which board it is working on and always was. TKT-250.
    $option{project} = $environment_project;

    my ( $browser_host, $browser_port );
    if ( $option{output} =~ /\Abrowser(?:=(.*))?\z/ ) {
        my $given = $1;
        if ( $command eq 'onboard' ) {
            # No project exists yet, so there is no remembered address to fall
            # back to - and a fixed default port would collide the moment two
            # projects tried to onboard at once. 127.0.0.1 rather than
            # 0.0.0.0: this is a disposable setup session, not a board meant
            # to be reached from another machine. 0.0.0.0 is refused outright
            # here, not merely defaulted away from - unlike tira.dashboard,
            # Tira::OnboardWeb has no login at all (by design: one submission
            # and done), so a network-reachable onboard session would be a
            # genuinely unauthenticated project-creation endpoint. TKT-527.
            ( $browser_host, $browser_port ) = ( '127.0.0.1', undef );
            if ( defined $given && length $given ) {
                return _error( $tira, 'toon',
                    "Unsupported browser endpoint '$given' - onboard has no login, so 0.0.0.0 is refused; use 127.0.0.1 or localhost\n" )
                  if $given =~ /\A0\.0\.0\.0(?::[0-9]+)?\z/;
                ( $browser_host, $browser_port ) = $given =~ /\A(127\.0\.0\.1|localhost)(?::([0-9]+))?\z/
                  or return _error( $tira, 'toon', "Unsupported browser endpoint '$given'\n" );
            }
            $browser_port = _free_port() if !defined $browser_port;
        }
        else {
            # Precedence, stated once: an address on the command line wins, the
            # project's remembered address is next, the original default last.
            my $endpoint = defined $given && length $given ? $given : do {
                my $stored = eval { $tira->project_show( project => $option{project} )->{dashboard} };
                join ':', ( $stored->{host} // '0.0.0.0' ), ( $stored->{port} // 7899 );
            };
            my $valid = eval {
                ( $browser_host, $browser_port ) = _browser_endpoint($endpoint);
                1;
            };
            return _error( $tira, 'toon', $@ || 'Invalid browser endpoint' ) if !$valid;
        }
    }

    # tira.onboard -o browser skips the interactive STDIN wizard entirely: a
    # disposable server collects the same answers over HTTP instead, then
    # calls back into the exact command dispatch every other onboard/create
    # answer reaches, so nothing forks into a second, divergent creation path.
    if ( $command eq 'onboard' && defined $browser_host ) {
        my $create = sub {
            my ($fields) = @_;
            my %merged = ( %option, %{$fields} );
            return _invoke( $tira, 'onboard', undef, \%merged );
        };
        # Same pre-fill the CLI wizard gives itself (_wizard_defaults) - the
        # browser form gets the identical suggested directory and defaults
        # lookup so editing an existing project is just as safe here.
        my $suggested = $option{dir}
          // eval { $tira->discover_project( defined $option{project} ? ( project => $option{project} ) : () ) }
          // '.';
        my $served = eval {
            $onboard_browser_server->(
                host => $browser_host, port => $browser_port, create => $create,
                dir  => $suggested, defaults => sub { _wizard_defaults( $tira, $_[0] ) },
                questions => $tira->onboarding_questions,
            );
            1;
        };
        return _error( $tira, 'toon', $@ || 'Unable to serve the onboarding session' ) if !$served;
        return 0;
    }

    # Only tira.onboard ever prompts. project.new stays purely argument-driven,
    # so no script or agent invoking it can be left waiting on input, and
    # onboard needs no terminal detection: without input it reaches end of
    # stream immediately and aborts rather than blocking.
    if ( $command eq 'onboard' ) {
        my ( $answers, $guided_status ) = _project_wizard( $tira, $guided_input // \*STDIN, \%option );
        if ( !$answers ) {
            print STDERR "Nothing was created.\n";
            return $guided_status;
        }
        %option = ( %option, %{$answers} );
    }

    my $cache;
    if ( defined $option{cache_ttl} && $option{cache_ttl} >= 1 && !$option{no_cache} ) {
        $cache = eval { _cache_context( $tira, $command, $type, \%option ) };
        if ( $cache && $cache->{hit} ) {
            print STDERR "tira: served from cache\n";
            print _utf8_bytes( $cache->{hit}{bytes} );
            return $cache->{hit}{status};
        }
    }
    my $result;
    my $ok = eval {
        $result = _invoke( $tira, $command, $type, \%option );
        1;
    };
    return _error( $tira, $option{output}, $@ || 'Unknown Tira failure' ) if !$ok;

    if ( $command eq 'attachment.get' ) {
        print $result->{content};
        return $result->{deleted} ? 1 : 0;
    }

    if ( defined $browser_host ) {

        # Whose board this is, recorded before anything forks. After a
        # pre-forked server has started there is no way for a process to tell
        # whether it is the master or a worker by asking itself, and the
        # difference decides whether a restart can possibly work.
        local $SERVING_PID = $$;

        my $render = sub {
            my %render_option = %option;
            $render_option{output} = 'table';
            my $dashboard = _invoke( $tira, $command, $type, \%render_option );
            return $tira->format_output(
                $dashboard, output => 'table', project => $option{project}, live => 1,
                with_title => defined $option{title},
            );
        };
        my $data = sub {
            my %data_option = %option;
            $data_option{output} = 'toon';
            $data_option{include_mtime} = 1;
            $data_option{with_questions} = 1;
            my $dashboard = _invoke( $tira, $command, $type, \%data_option );

            # A dashboard left open is running whatever Tira it started with.
            # Rather than making somebody visit every open board after an
            # update, the server notices and restarts itself into the new code;
            # the page then reloads when it sees a version it was not built by.
            #
            # Only the process that launched it may do that. This closure runs
            # in a worker under a pre-forked server, and a worker is not the
            # board: the master owns the listening socket, so a worker that
            # execs into a fresh dashboard cannot bind the port, dies, and is
            # replaced - taking the request with it. Four boards did exactly
            # that every sixty-five seconds for twenty hours without ever
            # upgrading, and it is why the page appeared to stop refreshing on
            # its own. Proved on an isolated board rather than reasoned about.
            my $restarted = _serving_pid() == $$
              && _restart_if_updated( $restarter, $command, $type, $option{project} );

            # And when it cannot, it says so instead of failing quietly once a
            # minute. The page reads this payload every sixty seconds already.
            if ( !$restarted ) {
                my $on_disk = _version_on_disk();
                $dashboard->{_stale} = $on_disk
                  if defined $on_disk && $on_disk ne $Tira::VERSION;
            }
            $dashboard->{_version} = $Tira::VERSION;
            return $tira->format_output( $dashboard, output => 'json', project => $option{project} );
        };
        # His decision, taken here and said out loud. A board serving sessions
        # that never expire is a different thing from one that does, and
        # somebody starting it should be able to tell without reading a manual.
        if ( $option{no_session_expire} ) {
            $Tira::SESSION_NEVER_EXPIRES = 1;
            print {*STDERR} "Sessions on this board never expire: a sign-in lasts until somebody signs out.\n"
              . "Over plain HTTP that cookie is a credential with no end date, so serve it somewhere you trust.\n";
        }

        # Over plain HTTP a password typed into the login page and the cookie
        # that follows it both travel in clear, which the documentation used to
        # admit rather than fix. A self-signed certificate stops somebody
        # reading them off the wire; it does not stop somebody who can already
        # stand in the middle, and saying so is part of offering it.
        my %tls;
        if ( $option{ssl} ) {
            my $certificate = $tira->tls_certificate( project => $option{project} );
            %tls = ( ssl_cert => $certificate->{certificate_path}, ssl_key => $certificate->{key_path} );
            print {*STDERR} "Serving over HTTPS with the board's own certificate.\n"
              . "It is self-signed, so a browser will warn the first time and you accept it once.\n"
              . "That stops somebody reading your password off the wire. It does not stop\n"
              . "somebody who can already stand between you and this machine.\n";
        }

        # Resolved here, because here is where the resolver is.
        #
        # A board may be referred to by something other than its path, and that
        # is deliberate: the agent working a project is never told where the
        # board actually sits. Only this process can turn one into the other -
        # it holds the resolver - and the workers that serve the board are
        # started fresh with nothing but the environment. Handing them what was
        # typed made every request fail inside a worker, with the port bound and
        # the board apparently up.
        my $serving = eval { $tira->discover_project( project => $option{project} ) };
        return _error( $tira, 'toon', $@ || 'Unable to resolve the board to serve' )
          if !defined $serving;

        my %providers = browser_providers( tira => $tira, project => $serving,
            store => $option{store} );
        my $served = eval {
            $browser_server->(
                host => $browser_host, port => $browser_port, render => $render, data => $data,

                # Which board, and how to show it. The workers load the
                # application themselves and cannot be handed a closure over
                # any of this, so it travels in the environment - and serve()
                # refuses without a project rather than starting workers that
                # die on load.
                project => $serving, type => $type,
                with_title => $option{with_title},
                %tls, %providers,
            );
            1;
        };
        return _error( $tira, 'toon', $@ || 'Unable to serve dashboard' ) if !$served;
        return 0;
    }

    if ( $option{output} eq 'human' && $option{count} && ref $result eq 'HASH' ) {
        print "$result->{count}\n";
        return _finish( $tira, \%option, $command, 0 );
    }
    if ( $option{output} eq 'human' && $option{refs_only} && ref $result eq 'ARRAY' ) {
        print _utf8_bytes( join '', map { "$_\n" } @{$result} );
        return _finish( $tira, \%option, $command, 0 );
    }
    # What was asked for, so the readable format can show that rather than
    # drawing its whole card template against a record it no longer has. Asking
    # for one field used to print a filled card as an empty one - no
    # description, unassigned, no priority - and leave out the field itself.
    my $formatted = eval {
        $tira->format_output( $result, output => $option{output}, project => $option{project},
            ( defined $option{field_selection} ? ( fields => $option{field_selection} ) : () ) );
    };
    return _error( $tira, 'toon', $@ || 'Unable to format output' ) if !defined $formatted;
    print _utf8_bytes($formatted);
    my $status = ( defined $option{if_changed} && ref $result eq 'HASH' && $result->{unchanged} ) ? 1 : 0;

    # Findings, told apart from clean and from could-not-look. An error already
    # exits 2, so this takes 1 and the three answers a checker needs are all
    # expressible. TKT-279.
    # Counting rows is the fallback, not the rule: it is right for every command
    # whose output IS its findings, and wrong for any that summarises, groups or
    # adds a heading. TKT-291 asks for grouping on this same command, so the
    # count has to come from the command rather than from what it printed.
    $status = 1
      if $option{exit_nonzero_if_any}
      && ( defined $option{findings_count}
        ? $option{findings_count}
        : ( ref $result eq 'ARRAY' && @{$result} ) );
    _cache_store( $cache, $formatted, $status ) if $cache;
    return _finish( $tira, \%option, $command, $status );
}

# Whatever the command was, an unresolved collector failure is shown
# under its output, because the collector itself had nobody to tell.
sub _finish {
    my ( $tira, $option, $command, $status ) = @_;
    return $status if $command =~ /\Awarning\./;
    my $warnings = eval { $tira->warning_list( project => $option->{project} ) } || [];
    return $status if !@{$warnings};
    my $banner = "\nAttention:\n"
      . join( '', map { "  [$_->{id}] $_->{at} $_->{message}\n" } @{$warnings} )
      . "Fix the cause, then clear with: tira.warning.clear --id <ID>"
      . " (or --all). Until then this shows under every command.\n";

    # A machine payload must stay parseable, so the banner goes where a human
    # and a coding agent both still read it without corrupting the output.
    if ( $option->{output} eq 'human' ) { print _utf8_bytes($banner) }
    else { print {*STDERR} _utf8_bytes($banner) }
    return $status;
}

# Where Tira's own board is, asked for by name rather than by path. The
# dashboard already resolves a skill name to its directory, and on somebody
# else's machine it resolves to their copy - which is right, because a bug
# report belongs to whoever owns the Tira that has the bug.
#
# Through a seam, so a test can answer the question without a real installation
# and without the answer ever being a path this skill hands out.
sub _tira_home {
    my $resolver = _dd_path_resolver();
    my $home = eval { $resolver->('tira') };
    die "Could not find Tira's own board to report this to. Report it to whoever\n"
      . "maintains Tira instead.\n"
      if !defined $home || $home eq '';
    return $home;
}

# An agent working on something else, reporting a fault in Tira. It knows what
# it found and which project it is; it is told nothing about where the report
# goes, which is the whole reason this exists rather than an instruction to go
# and find the board.
sub _report_to_tira {
    my ( $tira, $args, $option ) = @_;

    my $from = $option->{from};
    die "Which project is this coming from? Say so: --from <project>\n"
      . "A report nobody can go back to is a report nobody can answer.\n"
      if !defined $from || $from !~ /\S/;

    my $title = $option->{title};
    die "What did you find? Give it a title: --title <what happened>\n"
      if !defined $title || $title !~ /\S/;

    my $card = $tira->create_record(
        project  => _tira_home(),
        type     => 'ticket',
        title    => $title,

        # Raised as the owner. An agent in another project is not a member of
        # this board, and inventing a member per caller would fill the roster
        # with names nobody here works with. The origin is a label instead, so
        # the report can be found again and answered on the card.
        reporter    => 'michael',
        labels      => [$from],
        description => $option->{text} // '',
        source      => "Reported from $from through tira.dev.found.bug_or_improvement",
    );

    # What comes back names the card and nothing else. A path here would teach
    # the caller the one thing this command exists to keep from it.
    return {
        ref     => $card->{ref},
        from    => $from,
        message => "Reported as $card->{ref}. Somebody will pick it up; ask about it there.",
    };
}

sub _dd_path_resolver {
    return sub {
        my ($name) = @_;
        require Developer::Dashboard::Config;
        require Developer::Dashboard::FileRegistry;
        require Developer::Dashboard::PathRegistry;
        my $home = $ENV{HOME} // '';
        $home =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe home path\n";
        $home = $1;
        my $paths = Developer::Dashboard::PathRegistry->new(
            home => $home, cwd => cwd(), workspace_roots => [], project_roots => [],
        );
        my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
        my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );

        # Global aliases only, not path_aliases - which merges in whatever
        # repo-local .developer-dashboard.json is found by walking up from
        # the working directory, and a repo-local file can name the same
        # alias a global one already names. From two directories that
        # themselves held such a file, the identical name resolved to that
        # repo's board instead of the one a global alias had always meant -
        # silently, because config merging does not distinguish "this repo
        # extends the alias set" from "this repo means something different
        # by a name already taken". TKT-368. A board selector is a
        # user-level, stable idea by design (TKT-250: one way to name a
        # board, nothing to fall back on) - it is not a project setting a
        # repo should be able to override by merely being nearby.
        $paths->register_named_paths( $config->global_path_aliases );
        return $paths->resolve_dir($name);
    };
}

sub _browser_endpoint {
    my ($endpoint) = @_;
    $endpoint =~ /\A(0\.0\.0\.0|127\.0\.0\.1|localhost)(?::([0-9]+))?\z/
      or die "Unsupported browser endpoint '$endpoint'\n";
    my ( $host, $port ) = ( $1, defined $2 ? 0 + $2 : 7899 );
    die "Browser port must be between 1 and 65535\n" if $port < 1 || $port > 65535;
    return ( $host, $port );
}

# Through a seam so a test can watch the decision without a process replacing
# itself mid-suite. exec swaps this process for a new one - nothing is forked,
# and no shell is involved.
# The entrypoint this command was reached through. $0 is not reliable: under
# the dashboard dispatcher it is the dispatcher, so restarting on it re-ran the
# wrong program and the board died instead of updating. Derived from the module
# path and the command, and checked before anything is replaced.
sub _entrypoint_for {
    my ($command) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;
    my $root = File::Spec->rel2abs(
        File::Spec->catdir( dirname( dirname($1) ), File::Spec->updir ) );
    my @parts = split /\./, $command;
    my $action = pop @parts;
    my $path = @parts
      ? File::Spec->catfile( $root, 'skills', @parts, 'cli', $action )
      : File::Spec->catfile( $root, 'cli', $action );
    ($path) = $path =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;

    # Executability is what makes a file a command on a POSIX system. Windows
    # has no such bit, and -x there answers about the extension - so asking for
    # it found nothing, _entrypoint_for returned undef, and a dashboard on
    # Windows never picked up a new version however many were installed.
    return ( $WINDOWS ? -f $path : -x $path ) ? $path : undef;
}

sub _restart_into {
    my (@argv) = @_;
    my ($perl) = $^X =~ /\A([^\x00-\x1f\x7f]+)\z/ or return 0;
    my $script = shift @argv or return 0;

    # Both the interpreter and the script are absolute here, so the search path
    # is never consulted to find them; taint mode objects to it regardless.
    # Handing the restarted process a known-safe path is better than laundering
    # whatever this one happened to inherit, and better than wiping it.
    # Both are absolute, so the search path is never consulted to find them;
    # this is about what the restarted process inherits. The POSIX directories
    # mean nothing on Windows, where emptying the path would break the child
    # rather than protect it, so only the shell variables go there.
    local $ENV{PATH} = '/usr/local/bin:/usr/bin:/bin' if !$WINDOWS;
    delete local @ENV{qw(IFS CDPATH ENV BASH_ENV)};

    exec( $perl, $script, @argv );
}

# The version in the module a restart would load. installed_version() reads a
# label out of .env, and a label is not what exec changes - the file is. Asking
# the file is the only way to know whether restarting would run different code
# or the same code again.
sub _version_on_disk {
    my ($path) = @_;
    $path //= $INC{'Tira.pm'};
    return undef if !defined $path;
    $path =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;
    open my $fh, '<:raw', $1 or return undef;
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body =~ /^our \$VERSION = '([^']+)';/m ? $1 : undef;
}

sub _restart_if_updated {
    my ( $restarter, $command, $type, $project ) = @_;
    my $installed = Tira::installed_version();

    # Unreadable means unknown, and restarting on unknown would loop forever.
    return 0 if !defined $installed;

    # And so would restarting into the code already running. This used to
    # compare .env against the running version - two things a restart cannot
    # reconcile, because exec loads the same module again and disagrees with
    # .env again. His four boards did that every sixty seconds for twenty
    # hours, and the test suite did it once and hung for ever. The question is
    # not whether the label moved but whether the code did.
    my $on_disk = _version_on_disk();
    return 0 if !defined $on_disk || $on_disk eq $Tira::VERSION;

    # A restart that cannot work is worse than a stale board, because it turns
    # "running slightly old code" into "not running". So the target is checked
    # first, and if anything is missing the board simply carries on.
    my $script = _entrypoint_for( defined $type ? "$command.$type" : $command )
      // _entrypoint_for($command)
      or return 0;
    my @argv = grep { defined }
      map { /\A([^\x00-\x1f\x7f]*)\z/ ? $1 : undef } @Tira::CLI::RESTART_ARGV;
    return 0 if @argv != @Tira::CLI::RESTART_ARGV;

    # The board is handed over explicitly rather than left to be rediscovered,
    # so the new process does not depend on a working directory. It goes in the
    # environment because that is the only way to name a board now: there were
    # three - a flag, the environment and the working directory - and three
    # ways to say one thing is three behaviours to keep in agreement. It is set
    # rather than inherited, which is the same guarantee the flag gave.
    # TKT-250.
    return $restarter->( $script, @argv )
      if !defined $project || $project !~ /\S/;

    # Set for the new process rather than left to whatever it inherits, which
    # is the same guarantee the flag used to give. exec keeps the environment,
    # so naming it here is naming it there.
    local $ENV{TIRA_HOME} = $project;
    return $restarter->( $script, @argv );
}

sub _serve_browser {
    require Tira::DashboardWeb;
    return Tira::DashboardWeb->serve(@_);
}

sub _serve_onboard_browser {
    require Tira::OnboardWeb;
    return Tira::OnboardWeb->serve(@_);
}

# Chosen rather than fixed, because a fixed default is exactly the collision
# tira.dashboard -o browser's own port already accepts for a long-lived
# board with one obvious address - the wrong trade for a disposable session
# two people could start at once. The race between closing this socket and
# Plack::Runner binding the same port is the same one every "ask the OS for a
# free port" trick accepts; tools/browser-tests picks one the same way.
sub _free_port {
    require IO::Socket::INET;
    my $socket = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' )
      or die "Could not find a free port: $!\n";
    my $port = $socket->sockport;
    $socket->close;
    return $port;
}

# One provider set feeds both the CLI-launched Dancer2 server and the
# standalone dashboard.psgi, so browser mutations can never drift from the
# engine's validated command surface.
sub browser_providers {
    my (%args) = @_;
    my $tira = $args{tira};
    my $project = $args{project};
    my $json = Tira::json_object()->canonical;
    my %editable = map { $_ => 1 } qw(
        title description problem_or_feature solution_needed source
        sdlc_gate lifecycle fix_version assignee reporter priority
        start_date due_date
    );
    my %list_editable = (
        labels => 'labels_replace', affects_versions => 'affects_versions_replace',
        key_details => 'key_details_replace', deliverables => 'deliverables_replace',
        acceptance_criteria => 'acceptance_replace', test_steps => 'test_steps_replace',
        bdd => 'bdd_replace', atdd => 'atdd_replace',
        scope_included => 'scope', scope_excluded => 'scope',
    );
    return (
        move => sub {
            my ($payload) = @_;
            die "Move payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref column)) {
                die "Move payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my %move_args = (
                project => $project,
                ( defined $payload->{type} ? ( type => $payload->{type} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ref => $payload->{ref}, column => $payload->{column},
            );

            # The gating half of TKT-426 stays CLI/agent-only on purpose - a
            # human moving a card in the browser is not an agent skipping a
            # gate. But the bookkeeping half (populating a destination
            # column's required-action template, resetting one on the way
            # back through) is not enforcement, it is keeping the card
            # accurate for whoever looks at it next - and that has to happen
            # here too, or a browser move silently leaves required_items
            # stale in either direction. TKT-452.
            my $before = eval { $tira->record_show(%move_args) };
            my $from   = $before ? $before->{column} : undef;
            my $record = $tira->record_move(%move_args);

            # column_list (and the required-action bookkeeping below) needs a
            # concrete board type, unlike record_show/record_move above, which
            # resolve the record by ref alone (TKT-532) - recovered here from
            # the record record_move already loaded, so a caller is never
            # required to say what the engine can already tell for itself.
            my %column_args = ( %move_args, type => $record->{type} );
            my $columns = eval { $tira->column_list(%column_args) };
            _apply_column_required_actions( $tira, \%column_args, $from, $payload->{column}, $columns, $record )
              if ref $columns eq 'ARRAY';
            $record = $tira->record_show(%column_args) if ref $columns eq 'ARRAY';

            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        detail => sub {
            my ($payload) = @_;
            die "Record detail requires ref\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref};
            my $record = $tira->record_show(
                project => $project,
                ( defined $payload->{type} ? ( type => $payload->{type} ) : () ),
                ref => $payload->{ref},
            );
            return $json->encode($record);
        },
        # The browser goes through the same subroutines the command line goes
        # through, so a rule cannot be enforced in one and forgotten in the
        # other. A failed sign-in answers ok => false rather than dying,
        # because the login page has to show a message, not a stack trace.
        # Fetched only when somebody expands the section. A card has a great
        # deal happen to it, and loading all of it whenever a card is opened
        # would bury everything else on the card.
        work_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->work_log( project => $project, ref => $payload->{ref} ) );
        },

        # What police has said about this card, read when the card opens rather
        # than when a section is expanded: there is at most one line per thing
        # police has said, unlike the work log, and the section has to know
        # whether it has anything before it decides to appear at all.
        #
        # A card reference is required. Answering an unnamed card with the whole
        # board's enforcement log would put every other card's chasing on
        # whichever card happened to be open.
        police_log => sub {
            my ($payload) = @_;
            die "A card reference is required\n" if !defined $payload->{ref};
            return $json->encode(
                $tira->enforcement_log(
                    project => $project,
                    store   => $args{store}
                      // _police_store( $tira->discover_project( project => $project ) ),
                    ref     => $payload->{ref},
                ) );
        },
        login_page => sub {
            my $project_name = eval { $tira->project_show( project => $project )->{name} };
            return $tira->login_page_html( name => $project_name );
        },
        login_start => sub {
            my ($payload) = @_;
            my $token = eval {
                $tira->login_start(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !defined $token;
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token } );
        },
        login_register => sub {
            my ($payload) = @_;
            my $person = eval {
                $tira->login_register(
                    project => $project, id => $payload->{id},
                    password => $payload->{password},
                );
            };
            return $json->encode( { ok => Cpanel::JSON::XS::false } ) if !$person;
            my $token = $tira->login_start(
                project => $project, id => $payload->{id}, password => $payload->{password} );
            return $json->encode( { ok => Cpanel::JSON::XS::true, token => $token, claimed => Cpanel::JSON::XS::true } );
        },
        session_resume => sub {
            my ($payload) = @_;
            my $session = $tira->session_resume( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_peek => sub {
            my ($payload) = @_;
            my $session = $tira->session_peek( project => $project, token => $payload->{token} );
            return $json->encode( $session ? { %{$session} } : { person => undef } );
        },
        session_end => sub {
            my ($payload) = @_;
            my $ended = eval { $tira->session_end( project => $project, token => $payload->{token} ) };
            return $json->encode( { ok => $ended ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false } );
        },
        question_answer => sub {
            my ($payload) = @_;
            die "Answering needs a question and some text\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{text};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_answer(
                    project => $project, id => $payload->{id},
                    text => $payload->{text}, author => $payload->{author},
                ),
            } );
        },
        question_attach => sub {
            my ($payload) = @_;
            die "Attaching needs a question, a filename and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id}
              || !defined $payload->{filename} || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            die "That upload is empty\n" if !length $content;

            # The browser hands over bytes rather than a path, so they are
            # written somewhere the engine can take a path to and then removed.
            require File::Temp;
            my ( $fh, $path ) = File::Temp::tempfile(
                SUFFIX => ( $payload->{filename} =~ /(\.[A-Za-z0-9]+)\z/ ? $1 : '.bin' ) );
            binmode $fh;
            print {$fh} $content;
            close $fh;
            my $question = eval {
                $tira->question_attach(
                    project => $project, id => $payload->{id},
                    file => $path, to => $payload->{to},
                    filename => $payload->{filename} );
            };
            my $error = $@;
            unlink $path;
            die $error if !$question;
            return $json->encode( { ok => Cpanel::JSON::XS::true, question => $question } );
        },
        question_mark => sub {
            my ($payload) = @_;
            die "Marking needs a question and a mark\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{mark};
            return $json->encode( {
                ok => Cpanel::JSON::XS::true,
                question => $tira->question_mark(
                    project => $project, id => $payload->{id}, mark => $payload->{mark} ),
            } );
        },
        columns => sub {
            my ($query) = @_;
            my $list = $tira->column_list( project => $project, type => $query->{type} );

            # Which columns already start new cards, so the dialog's own
            # checkbox opens showing what tira.column.roles --role entry=X
            # already declared, rather than always opening blank. TKT-494.
            my $declared = eval { $tira->column_roles( project => $project, type => $query->{type} )->{entry} };
            my @entries = ref $declared eq 'ARRAY' ? @{$declared}
              : ( defined $declared && $declared ne '' ? ($declared) : () );
            my %is_entry = map { $_ => 1 } @entries;
            $_->{entry} = $is_entry{ $_->{name} } ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
              for @{$list};
            return $json->encode($list);
        },
        column_apply => sub {
            my ($payload) = @_;
            die "Column layout must be an object with a type and columns\n"
              if ref($payload) ne 'HASH' || ref $payload->{columns} ne 'ARRAY';
            my $result = $tira->column_apply(
                project => $project, type => $payload->{type},
                columns => $payload->{columns},
            );

            # An 'entry' field is which columns the dialog's own checkboxes
            # left checked - a full replacement of the entry role, the same
            # semantics tira.column.roles --role entry=X already has, not an
            # add-only merge. Omitted entirely (not an empty array) means the
            # save was only ever about layout, so the existing entry columns
            # are left exactly as they were. TKT-494.
            if ( exists $payload->{entry} && ref $payload->{entry} eq 'ARRAY' ) {
                $tira->column_roles_set(
                    project => $project, type => $payload->{type},
                    roles   => { entry => $payload->{entry} },
                );
            }
            return $json->encode($result);
        },
        # The board-wide police policy engine, separate from a column's own
        # required-action template (the columns/column_apply pair above): 36
        # rules covering things a column dialog cannot express at all -
        # conversation-not-folded, question-unanswered, card-stalled and the
        # rest. Requested directly: "create a new modal on the html
        # dashboard, the user can view and edit and add the policies not
        # just column policies." TKT-493.
        policies => sub {
            return $json->encode( {
                declared     => $tira->policy_list( project => $project ),
                declined     => $tira->policy_declined( project => $project ),
                undeclared   => $tira->policy_undeclared( project => $project ),
                rules        => $tira->policy_rule_specs(),
                actions      => $tira->policy_actions(),
                token_fields => $tira->policy_message_fields(),
                token_help   => $tira->policy_message_field_help(),
            } );
        },
        policy_add => sub {
            my ($payload) = @_;
            die "Policy payload must be an object\n" if ref($payload) ne 'HASH';

            # Every field policy.add itself accepts, so nothing typeable on
            # the command line is unreachable from the dashboard - the same
            # completeness bar TKT-493's own acceptance criteria set.
            my %policy = map { $_ => $payload->{$_} }
              grep { defined $payload->{$_} && $payload->{$_} ne '' }
              qw(rule action enter before column age read_age max pattern
                 message require sandbox require_link link_to
                 type on_column ref);
            return $json->encode(
                $tira->policy_add( project => $project, %policy ) );
        },
        policy_remove => sub {
            my ($payload) = @_;
            die "A policy id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode(
                $tira->policy_remove( project => $project, id => $payload->{id} ) );
        },
        policy_decline => sub {
            my ($payload) = @_;
            die "A policy rule is required\n" if !defined $payload->{rule} || $payload->{rule} eq '';
            return $json->encode(
                $tira->policy_decline(
                    project => $project, rule => $payload->{rule}, reason => $payload->{reason},
                    ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                ) );
        },

        # TKT-516: the Task List section's own providers, one per CLI verb -
        # full parity, his words, so every one of these exists even where a
        # thin dashboard control is all it needs.
        tasklist => sub {
            my ($query) = @_;
            return $json->encode(
                $tira->tasklist_list( project => $project, session => $query->{session} // '' ) );
        },
        tasklist_add => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            return $json->encode( $tira->tasklist_add(
                project => $project, text => $payload->{text}, session => $payload->{session} // '',
                refs => $payload->{refs} // [],
            ) );
        },
        tasklist_update => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode( $tira->tasklist_update(
                project => $project, id => $payload->{id}, status => $payload->{status},
                text => $payload->{text}, session => $payload->{session} // '' ) );
        },
        tasklist_next => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_next( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_shift => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_shift( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_pop => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_pop( project => $project, session => $payload->{session} // '' ) // {} );
        },
        tasklist_unshift => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            return $json->encode( $tira->tasklist_unshift(
                project => $project, text => $payload->{text}, session => $payload->{session} // '' ) );
        },
        tasklist_slice => sub {
            my ($payload) = @_;
            die "Task text is required\n" if !defined $payload->{text} || $payload->{text} eq '';
            die "A position is required\n" if !defined $payload->{position};
            return $json->encode( $tira->tasklist_slice(
                project => $project, text => $payload->{text}, position => $payload->{position},
                session => $payload->{session} // '' ) );
        },
        tasklist_remove => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            return $json->encode( $tira->tasklist_remove(
                project => $project, id => $payload->{id}, session => $payload->{session} // '' ) );
        },
        tasklist_import => sub {
            my ($payload) = @_;
            die "A card ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_import(
                project => $project, ref => $payload->{ref}, session => $payload->{session} // '' ) );
        },
        tasklist_prune => sub {
            my ($payload) = @_;
            return $json->encode(
                $tira->tasklist_prune( project => $project, session => $payload->{session} // '' ) );
        },
        tasklist_task_attach_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires id, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{id} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            return $json->encode( $tira->tasklist_task_attach_add_content(
                project => $project, id => $payload->{id},
                filename => $payload->{filename}, content => $content,
                session => $payload->{session} // '',
            ) );
        },
        tasklist_task_attach_discard => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A filename is required\n" if !defined $payload->{filename} || $payload->{filename} eq '';
            return $json->encode( $tira->tasklist_task_attach_discard(
                project => $project, id => $payload->{id}, files => [ $payload->{filename} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_task_ref_link => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_task_ref_link(
                project => $project, id => $payload->{id}, refs => [ $payload->{ref} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_task_ref_unlink => sub {
            my ($payload) = @_;
            die "A task id is required\n" if !defined $payload->{id} || $payload->{id} eq '';
            die "A ref is required\n" if !defined $payload->{ref} || $payload->{ref} eq '';
            return $json->encode( $tira->tasklist_task_ref_unlink(
                project => $project, id => $payload->{id}, refs => [ $payload->{ref} ],
                session => $payload->{session} // '' ) );
        },
        tasklist_sessions => sub {
            return $json->encode( $tira->tasklist_sessions( project => $project ) );
        },

        search => sub {
            my ($query) = @_;

            # No type: the board filter searches the whole project, because a
            # question reference can name a card on any board.
            return $json->encode( [] ) if !defined $query->{text} || $query->{text} eq '';
            return $json->encode(
                $tira->search(
                    project => $project, text => $query->{text},
                    ( defined $query->{type} && $query->{type} ne '' ? ( type => $query->{type} ) : () ),
                    refs_only => 1,
                )
            );
        },
        create => sub {
            my ($payload) = @_;
            die "Create payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(type column title)) {
                die "Create payload requires type, column, and title\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || $payload->{$key} eq '';
            }
            my %optional;
            for my $field (qw(description priority assignee reporter)) {
                next if !defined $payload->{$field} || $payload->{$field} eq '';
                die "Field '$field' requires a plain value\n" if ref $payload->{$field};
                $optional{$field} = $payload->{$field};
            }
            $optional{reporter} = $payload->{_signed_in}
              if !defined $optional{reporter} && defined $payload->{_signed_in};
            my $record = $tira->create_record(
                project => $project, type => $payload->{type}, title => $payload->{title},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
                %optional,
            );
            $record = $tira->record_move(
                project => $project, ref => $record->{ref}, column => $payload->{column},
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            ) if $payload->{column} ne 'backlog';
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        update => sub {
            my ($payload) = @_;
            die "Update payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref field)) {
                die "Update payload requires ref, field, and value\n"
                  if !defined $payload->{$key} || ref $payload->{$key} || !exists $payload->{value};
            }
            my $field = $payload->{field};
            my $value = $payload->{value};
            if ( $list_editable{$field} ) {
                die "Field '$field' requires an array value\n" if ref $value ne 'ARRAY';
                die "Field '$field' accepts plain text items only\n" if grep { ref $_ || !defined $_ } @{$value};
                my %change;
                if ( $field =~ /\Ascope_(included|excluded)\z/ ) {
                    my $side = $1;
                    my $scope = $tira->record_show( project => $project, ref => $payload->{ref} )->{scope};
                    $change{scope} = { %{ $scope // {} }, $side => $value };
                }
                else {
                    $change{ $list_editable{$field} } = $value;
                }
                my $record = $tira->record_update(
                    project => $project, ref => $payload->{ref},
                    author => $payload->{author} // $payload->{_signed_in}, %change );
                return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
            }
            die "Field '$field' is not editable\n" if !$editable{$field};
            die "Field '$field' requires a plain value\n" if ref $value;
            die "Update base must be a plain value\n" if exists $payload->{base} && ref $payload->{base};
            my $record = $tira->record_update(
                project => $project, ref => $payload->{ref},
                author => $payload->{author} // $payload->{_signed_in}, $field => $value,
                ( exists $payload->{base} ? ( expect => { $field => $payload->{base} } ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, record => $record } );
        },
        link_types => sub {
            return $json->encode(
                [ map { { outward => $_->{outward}, inward => $_->{inward} } }
                  @{ $tira->link_type_list( project => $project ) } ]
            );
        },
        ( map {
            my ( $name, $method ) = @{$_};
            ( $name => sub {
                my ($payload) = @_;
                die ucfirst( $name =~ tr/_/ /r ) . " requires parent and child\n"
                  if ref($payload) ne 'HASH'
                  || !defined $payload->{parent} || ref $payload->{parent}
                  || !defined $payload->{child} || ref $payload->{child};
                my $result = $tira->$method(
                    project => $project, parent => $payload->{parent}, child => $payload->{child},
                );
                return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
            } );
        } ( [ hierarchy_link => 'hierarchy_link' ], [ hierarchy_unlink => 'hierarchy_unlink' ],
            [ subitem_link => 'subitem_link' ], [ subitem_unlink => 'subitem_unlink' ] ) ),
        link_add => sub {
            my ($payload) = @_;
            die "Link add requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $link = $tira->link_add(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, link => $link } );
        },
        link_remove => sub {
            my ($payload) = @_;
            die "Link removal requires from, type, and to\n"
              if ref($payload) ne 'HASH'
              || grep { !defined $payload->{$_} || ref $payload->{$_} } qw(from type to);
            my $result = $tira->link_remove(
                project => $project, from => $payload->{from},
                type => $payload->{type}, to => $payload->{to},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, result => $result } );
        },
        checklist_add => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref item status)) {
                die "Checklist add requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $entry = $tira->checklist_add(
                project => $project, ref => $payload->{ref}, author => $payload->{author} // $payload->{_signed_in},
                item => $payload->{item}, status => $payload->{status},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        checklist_update => sub {
            my ($payload) = @_;
            die "Checklist payload must be an object\n" if ref($payload) ne 'HASH';
            die "Checklist update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->checklist_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                author => $payload->{author} // $payload->{_signed_in},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
                ( defined $payload->{command} ? ( command => $payload->{command} ) : () ),
                ( defined $payload->{proof} ? ( proof => $payload->{proof} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        required_action_update => sub {
            my ($payload) = @_;
            die "Required action payload must be an object\n" if ref($payload) ne 'HASH';
            die "Required action update requires ref and id\n"
              if !defined $payload->{ref} || ref $payload->{ref} || !defined $payload->{id} || ref $payload->{id};
            my $entry = $tira->required_item_update(
                project => $project, ref => $payload->{ref}, id => $payload->{id},
                author => $payload->{author} // $payload->{_signed_in},
                ( defined $payload->{item} ? ( item => $payload->{item} ) : () ),
                ( defined $payload->{status} ? ( status => $payload->{status} ) : () ),
                ( defined $payload->{command} ? ( command => $payload->{command} ) : () ),
                ( defined $payload->{proof} ? ( proof => $payload->{proof} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, entry => $entry } );
        },
        comment_add => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';

            # A comment is personal, unlike an assignment or a move - TKT-458.
            # Everywhere else on the board an explicit author is a deliberate
            # override the session defers to; here it is the one thing a
            # signed-in person cannot hand to someone else by picking wrong,
            # so the session wins even over an author the payload names.
            $payload->{author} = $payload->{_signed_in}
              if defined $payload->{_signed_in};
            for my $key (qw(ref author text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            die "Project person '$payload->{author}' is inactive\n"
              if grep { $_->{id} eq $payload->{author} && !$_->{active} }
              @{ $tira->person_list( project => $project ) };
            my $comment = $tira->comment_add(
                project => $project, ref => $payload->{ref},
                author => $payload->{author}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_update => sub {
            my ($payload) = @_;
            die "Comment payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment text)) {
                die "Comment payload requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }

            # Same reasoning as comment_add (TKT-458): a comment is personal,
            # so the signed-in session is who edited it - not something a
            # client-sent field could override even if it tried to. TKT-466.
            my $comment = $tira->comment_update(
                project => $project, ref => $payload->{ref},
                author => $payload->{_signed_in} // $payload->{author},
                comment => $payload->{comment}, text => $payload->{text},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, comment => $comment } );
        },
        comment_remove => sub {
            my ($payload) = @_;
            die "Comment removal payload must be an object\n" if ref($payload) ne 'HASH';
            for my $key (qw(ref comment)) {
                die "Comment removal requires $key\n" if !defined $payload->{$key} || ref $payload->{$key};
            }
            my $removed = $tira->comment_remove(
                project => $project, ref => $payload->{ref}, comment => $payload->{comment},
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, removed => $removed } );
        },
        people => sub {
            return $json->encode(
                [ map { { id => $_->{id}, name => $_->{name} } }
                  grep { $_->{active} } @{ $tira->person_list( project => $project ) } ]
            );
        },
        attachment_fetch => sub {
            my ($payload) = @_;
            die "Attachment fetch requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $got = $tira->attachment_get(
                project => $project, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
            );
            die "Attachment '$payload->{sha}' not found\n" if $got->{deleted};
            my $record = $tira->record_show( project => $project, ref => $payload->{ref} );
            my ($reference) =
              grep { $_->{sha} eq $payload->{sha} }
              ( @{ $record->{attachments} }, map { @{ $_->{attachments} // [] } } @{ $record->{comments} } );
            my $extension = $payload->{extension} // ( $reference ? $reference->{extension} : 'bin' );
            my $filename = $reference ? $reference->{original_filename} : "$payload->{sha}.$extension";
            return {
                content => $got->{content},
                content_type => _attachment_content_type($extension),
                filename => $filename,
                inline => _attachment_content_type($extension) eq 'application/octet-stream' ? 0 : 1,
            };
        },
        attachment_add => sub {
            my ($payload) = @_;
            die "Attachment upload requires ref, filename, and content\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{filename}
              || !defined $payload->{content_base64};
            require MIME::Base64;
            my $content = MIME::Base64::decode_base64( $payload->{content_base64} );
            my $attachment = $tira->attachment_add_content(
                project => $project, ref => $payload->{ref},
                filename => $payload->{filename}, content => $content,
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, attachment => $attachment } );
        },
        attachment_discard => sub {
            my ($payload) = @_;
            die "Discard payload must be an object\n" if ref($payload) ne 'HASH';
            my $reference = $tira->attachment_discard(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                extension => $payload->{extension},
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
                ( defined $payload->{_signed_in} ? ( author => $payload->{_signed_in} ) : () ),
            );
            return Tira::json_object()->canonical->encode(
                { ok => Cpanel::JSON::XS::true, attachment => $reference } );
        },

        attachment_remove => sub {
            my ($payload) = @_;
            die "Attachment removal requires ref and sha\n"
              if ref($payload) ne 'HASH' || !defined $payload->{ref} || !defined $payload->{sha};
            my $result = $tira->attachment_detach(
                project => $project, ref => $payload->{ref}, sha => $payload->{sha},
                ( defined $payload->{extension} ? ( extension => $payload->{extension} ) : () ),
                ( defined $payload->{comment} ? ( comment => $payload->{comment} ) : () ),
            );
            return $json->encode( { ok => Cpanel::JSON::XS::true, %{$result} } );
        },
    );
}

# The viewer forces text-like content (html included) to plain text so
# nothing fetched from the store can execute inside the dialog's frame.
# CA18: per-call opt-in read-through cache. Entries live under the
# project's own .tira/cache (never a shared temp path), key on the full
# argument set, and are valid only while both the ttl holds and a board
# fingerprint (hi-res mtimes of the config, boards, columns, and
# attachment store) is unchanged — so any write invalidates immediately
# and a caller can never read its own stale data. A corrupt entry warns
# and falls back to a live read; a hit is always reported on stderr.
sub _board_fingerprint {
    my ($root) = @_;
    require Time::HiRes;
    my @stamps;
    my @paths = (
        File::Spec->catfile( $root, '.tira', 'project.yml' ),
        File::Spec->catdir( $root, '.tira', 'attachments' ),
    );

    # The counter Tira raises on every write. Modification times are the same
    # for two writes inside one clock tick on Windows - about sixteen
    # milliseconds - so a caller could be served the board as it was before its
    # own write. This has no clock in it.
    my $generation = File::Spec->catfile( $root, '.tira', '.generation' );
    if ( open my $fh, '<', $generation ) {
        my $line = <$fh>;
        close $fh;
        push @stamps, 'generation=' . ( defined $line ? $line : '' );
    }
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        push @paths, $board;
        my $dh;
        next if !opendir $dh, $board;
        my @entries = map { File::Spec->catdir( $board, $_ ) }
          sort grep { !/\A\./ } readdir $dh;
        closedir $dh;
        push @paths, @entries;

        # And the records themselves. A directory's modification time answers a
        # different question from the one being asked here: it changes when the
        # set of names changes, not when a file's contents do. A card edited in
        # place adds and removes no name, so on Windows the directory was
        # untouched, the cache was judged current, and the caller was served the
        # board as it was before its own write.
        for my $column ( grep { -d } @entries ) {
            my $files;
            next if !opendir $files, $column;
            push @paths, map { File::Spec->catfile( $column, $_ ) }
              sort grep { /\.json\z/ } readdir $files;
            closedir $files;
        }
    }
    for my $path (@paths) {
        my @stat = Time::HiRes::stat($path);
        push @stamps, $path . '=' . ( @stat ? $stat[9] : 'absent' );
    }
    return join ';', @stamps;
}

sub _cache_context {
    my ( $tira, $command, $type, $option ) = @_;
    my $root = $tira->discover_project( project => $option->{project} );
    ($root) = $root =~ /\A(.+)\z/s;
    my $key_source = Tira::json_object()->canonical->encode( {
        command => $command, type => $type,
        map { $_ => $option->{$_} }
          grep { defined $option->{$_} && $_ ne 'cache_ttl' && $_ ne 'no_cache' }
          sort keys %{$option},
    } );
    my $key = Digest::SHA::sha256_hex( encode_utf8($key_source) );
    my $dir = File::Spec->catdir( $root, '.tira', 'cache' );
    my $file = File::Spec->catfile( $dir, "$key.json" );
    my $context = {
        dir => $dir, file => $file, ttl => $option->{cache_ttl},
        fingerprint => _board_fingerprint($root),
    };
    if ( -f $file ) {
        require MIME::Base64;
        my $entry = eval {
            open my $fh, '<:raw', $file or die "unreadable\n";
            local $/;
            Tira::json_decode(<$fh>);
        };
        if ( !$entry || ref $entry ne 'HASH' || !defined $entry->{bytes} ) {
            print STDERR "tira: discarding corrupt cache entry\n";
        }
        elsif ( time() - ( $entry->{stored_at} // 0 ) <= $context->{ttl}
            && ( $entry->{fingerprint} // '' ) eq $context->{fingerprint} ) {
            $context->{hit} = {
                bytes => Encode::decode( 'UTF-8', MIME::Base64::decode_base64( $entry->{bytes} ) ),
                status => $entry->{status} // 0,
            };
        }
    }
    return $context;
}

sub _cache_store {
    my ( $context, $formatted, $status ) = @_;
    eval {
        require MIME::Base64;
        File::Path::make_path( $context->{dir} ) if !-d $context->{dir};
        my ( $fh, $temp ) = File::Temp::tempfile( DIR => $context->{dir}, SUFFIX => '.tmp' );
        binmode $fh, ':raw';
        print {$fh} Tira::json_object()->canonical->encode( {
            stored_at => time(), fingerprint => $context->{fingerprint},
            status => $status, bytes => MIME::Base64::encode_base64( _utf8_bytes($formatted), '' ),
        } );
        close $fh;
        rename $temp, $context->{file} or die "rename failed\n";
        1;
    } or print STDERR "tira: unable to store cache entry\n";
    return;
}

# The guided setup behind tira.onboard. Plain reads and writes — no terminal control
# codes, no new dependency, nothing spawned — so the command stays taint-clean.
# It is only ever entered deliberately (see the caller): a wizard that reads
# standard input would otherwise hang every script and agent that runs the
# command without arguments, which is most of them.
# a leading ~ means the user's home directory wherever it is typed.
# The shell expands it for an unquoted command-line argument, but never for an
# answer typed at a prompt or for a quoted flag — which is how a directory
# literally named '~' gets created.
sub _expand_home {
    my ($path) = @_;
    return $path if !defined $path || $path !~ m{\A~(?:/|\z)};
    my ($home) = ( $ENV{HOME} // '' ) =~ /\A([^\x00-\x1f\x7f]*)\z/;
    return $path if !defined $home || $home eq '';
    $path =~ s{\A~}{$home};
    return $path;
}

# Line editing without a dependency: Term::ReadLine's editing implementations
# are not installed anywhere this runs, so relying on one would silently give
# the user nothing. POSIX termios is core, so the editor is written directly
# against it and degrades to a plain read whenever input is not a terminal.
sub _raw_mode {
    my ($fh) = @_;
    my $fd = fileno($fh);
    return undef if !defined $fd || $fd < 0 || !-t $fh;
    require POSIX;
    my $saved = POSIX::Termios->new;
    return undef if !eval { $saved->getattr($fd) };
    my $raw = POSIX::Termios->new;
    $raw->getattr($fd);
    $raw->setlflag( ( $raw->getlflag // 0 ) & ~( POSIX::ICANON() | POSIX::ECHO() ) );
    $raw->setcc( POSIX::VMIN(),  1 );
    $raw->setcc( POSIX::VTIME(), 0 );
    $raw->setattr( $fd, POSIX::TCSANOW() );
    return sub { $saved->setattr( $fd, POSIX::TCSANOW() ); return };
}

sub _redraw {
    my ( $prompt, $buffer, $cursor ) = @_;
    my $column = length($prompt) + $cursor + 1;
    print "\r\e[2K$prompt$buffer\r\e[${column}G";
    return;
}

# Returns the finished line, or undef when the user abandons the prompt.
sub _edit_line {
    my ( $in, $prompt, $restore ) = @_;
    my ( $buffer, $cursor ) = ( '', 0 );
    _redraw( $prompt, $buffer, $cursor );
    while (1) {
        my $char = getc($in);
        if ( !defined $char || $char eq "\x04" || $char eq "\x03" ) {
            $restore->();
            print "\n";
            return undef;
        }
        if ( $char eq "\r" || $char eq "\n" ) {
            $restore->();
            print "\n";
            return $buffer;
        }
        if ( $char eq "\x01" ) { $cursor = 0 }                        # Ctrl-A
        elsif ( $char eq "\x05" ) { $cursor = length $buffer }        # Ctrl-E
        elsif ( $char eq "\x15" ) { $buffer = ''; $cursor = 0 }       # Ctrl-U
        elsif ( $char eq "\x0b" ) { substr $buffer, $cursor, length($buffer) - $cursor, '' }  # Ctrl-K
        elsif ( $char eq "\x7f" || $char eq "\x08" ) {
            if ( $cursor > 0 ) { substr $buffer, --$cursor, 1, '' }
        }
        elsif ( $char eq "\e" ) {
            my $bracket = getc($in);
            my $code = defined $bracket && $bracket eq '[' ? getc($in) : undef;
            if ( defined $code ) {
                if    ( $code eq 'D' ) { $cursor-- if $cursor > 0 }
                elsif ( $code eq 'C' ) { $cursor++ if $cursor < length $buffer }
                elsif ( $code eq 'H' ) { $cursor = 0 }
                elsif ( $code eq 'F' ) { $cursor = length $buffer }
            }
        }
        elsif ( $char =~ /\A[[:print:]]\z/ ) {
            substr $buffer, $cursor, 0, $char;
            $cursor++;
        }
        _redraw( $prompt, $buffer, $cursor );
    }
}

sub _ask {
    my ( $in, $question, $default ) = @_;
    my $shown = defined $default && $default ne '' ? " [$default]" : '';
    my $prompt = "$question$shown: ";
    my $answer;
    if ( my $restore = _raw_mode($in) ) {
        $answer = _edit_line( $in, $prompt, $restore );
    }
    else {
        print $prompt;
        $answer = <$in>;
    }
    return undef if !defined $answer;
    chomp $answer;
    $answer =~ s/\A\s+|\s+\z//g;
    return length $answer ? $answer : ( defined $default ? $default : '' );
}

sub _ask_yes {
    my ( $in, $question, $default ) = @_;
    while (1) {
        my $answer = _ask( $in, "$question [" . ( $default ? 'Y/n' : 'y/N' ) . ']', '' );
        return undef if !defined $answer;
        return $default if $answer eq '';
        return 1 if $answer =~ /\Ay(?:es)?\z/i;
        return 0 if $answer =~ /\An(?:o)?\z/i;
        print "  Please answer yes or no.\n";
    }
}

# Is there a coding agent on this machine at all? Its own sub so a
# test can drive both answers, rather than proving whichever one this
# particular machine happens to give.
# PATH is separated by a colon on POSIX and a semicolon on Windows, and a
# program there is executable because of its extension rather than a mode bit.
# Splitting on a colon and looking for an extensionless file found nothing on
# Windows however much was installed, and answered "no agent" rather than
# failing - so onboarding quietly offered nothing.

# One search for "is this program here", used by everything that asks.
#
# There were two. This one knew that a program on Windows is called name.exe
# and that -x there answers for the extension rather than the file; the one the
# world gatherer used knew neither, so it found no git on Windows and every
# fact built on git came back empty. Two searches for the same thing drift
# apart the first time somebody fixes only the one they are looking at, which
# is exactly what happened.
sub _agent_available {
    my ($name) = @_;
    my @suffixes = $WINDOWS ? ( split /;/, $ENV{PATHEXT} // '.COM;.EXE;.BAT;.CMD' ) : ('');

    # Split on the separator the platform being described uses, rather than
    # asking File::Spec, which answers for the platform this is running on and
    # so cannot be driven from anywhere else.
    my $separator = $WINDOWS ? ';' : ':';
    for my $dir ( split /\Q$separator\E/, $ENV{PATH} // '' ) {
        next if !length $dir;
        for my $suffix (@suffixes) {

            # PATHEXT is conventionally upper case and the program on disk
            # conventionally is not. Windows itself does not care, because its
            # filesystem does not - but the same code runs under WSL, on
            # network shares, and in NTFS directories with case sensitivity
            # turned on, where it does. Trying both costs nothing and stops
            # this depending on which of those it happens to be.
            for my $spelling ( $suffix, lc $suffix ) {
                my $candidate = File::Spec->catfile( $dir, "$name$spelling" );
                return 1 if $WINDOWS ? -f $candidate : -x $candidate;
            }
        }
    }
    return 0;
}

# Everything an existing project already knows, so re-running onboarding is a
# matter of pressing enter rather than typing it all again.
sub _wizard_defaults {
    my ( $tira, $dir ) = @_;
    return {} if !defined $dir || $dir eq '';
    my $project = eval { $tira->project_show( project => $dir ) } or return {};
    my %defaults = ( name => $project->{name} );
    my @people = map { $_->{id} } @{ $project->{people} // [] };
    $defaults{members} = [ join ', ', @people ] if @people;
    $defaults{$_} = $project->{$_}
      for grep { defined $project->{$_} } qw(collector agent session heartbeat notify_after);
    my $mode = eval { $tira->project_mode( project => $dir ) };
    $defaults{mode} = $mode if defined $mode;
    my %columns;
    for my $type (qw(sow epic ticket)) {
        my $refs = eval { $tira->board_refs( project => $dir, type => $type ) };
        $defaults{"${type}_prefix"} = $refs->{prefix} if $refs;
        my $list = eval { $tira->column_list( project => $dir, type => $type ) } or next;
        $columns{$type} = join ', ', map { $_->{label} // $_->{name} } @{$list};
        $defaults{"${type}_columns"} = [ $columns{$type} ];
    }
    my @distinct = keys %{ { map { $_ => 1 } values %columns } };
    $defaults{columns} = [ $distinct[0] ] if @distinct == 1;
    $defaults{columns_shared} = ( @distinct == 1 ? 1 : 0 ) if %columns;
    return \%defaults;
}

# Command-line flags win over what the project already stores, but only over
# the project they were given for: naming a different one rebuilds the defaults
# from scratch rather than merging, so a setting the new project does not have
# cannot be inherited from the old one by pressing enter.
sub _wizard_all_defaults {
    my ( $tira, $dir, $option ) = @_;
    my $stored = _wizard_defaults( $tira, $dir );
    my %default = ( %{$stored},
        map { $_ => $option->{$_} } grep { defined $option->{$_} } keys %{$option} );
    return ( $stored, \%default );
}

sub _project_wizard {
    my ( $tira, $in, $option ) = @_;
    print "Tira project setup — answer the questions, or press Ctrl-D to abort.\n\n";
    my %answers;

    # The directory comes first because everything else can be pre-filled from
    # the project already living there. Asking it second would mean offering
    # one project's answers while writing to another.
    # Asking first is only useful if it can answer itself: offer whatever
    # project is already resolvable rather than making somebody type the path
    # before any of the pre-filling can help.
    my $suggested = $option->{dir}
      // eval {
        $tira->discover_project( defined $option->{project} ? ( project => $option->{project} ) : () );
      }
      // '.';
    my ( $stored, $default ) = _wizard_all_defaults( $tira, $suggested, $option );
    my $dir = _ask( $in, 'Project directory', $suggested );
    return ( undef, 2 ) if !defined $dir;
    $answers{dir} = _expand_home($dir);
    ( $stored, $default ) = _wizard_all_defaults( $tira, $answers{dir}, $option )
      if $answers{dir} ne $suggested;
    print "\nEditing the project already at that directory — press enter to keep each answer.\n\n"
      if %{$stored};

    while (1) {
        my $name = _ask( $in, 'Project name', $default->{name} );
        return ( undef, 2 ) if !defined $name;
        if ( $name eq '' ) {
            print "  A project needs a name.\n";
            next;
        }
        $answers{name} = $name;
        last;
    }

    my $members = _ask( $in, 'People, separated by commas',
        $default->{members} ? join( ', ', @{ $default->{members} } ) : '' );
    return ( undef, 2 ) if !defined $members;
    # Enter means "none yet", not "a person with an empty name" — the
    # empty-string guard exists for an explicit --members "" on a command line.
    $answers{members} = [$members] if $members ne '';

    my %default_prefix = ( sow => 'SOW', epic => 'EPC', ticket => 'TKT' );
    for my $type (qw(sow epic ticket)) {
        while (1) {
            my $prefix = _ask( $in, "Reference prefix for \u$type records",
                $default->{"${type}_prefix"} // $default_prefix{$type} );
            return ( undef, 2 ) if !defined $prefix;
            if ( $prefix !~ /\A[A-Z][A-Z0-9-]{0,31}\z/ ) {
                print "  Invalid prefix: it must start with a capital letter and use capitals, digits, and hyphens.\n";
                next;
            }
            $answers{"${type}_prefix"} = $prefix;
            last;
        }
    }

    my $shared = _ask_yes( $in, 'Do all three boards use the same columns?',
        $default->{columns_shared} // 1 );
    return ( undef, 2 ) if !defined $shared;
    if ($shared) {
        my $columns = _ask( $in, 'Columns, in order, separated by commas',
            $default->{columns} ? join( ', ', @{ $default->{columns} } ) : '' );
        return ( undef, 2 ) if !defined $columns;
        $answers{columns} = [$columns] if $columns ne '';
    }
    else {
        for my $type (qw(sow epic ticket)) {
            my $columns = _ask( $in, "Columns for the \u$type board",
                $default->{"${type}_columns"} ? join( ', ', @{ $default->{"${type}_columns"} } ) : '' );
            return ( undef, 2 ) if !defined $columns;
            $answers{"${type}_columns"} = [$columns] if $columns ne '';
        }
    }

    # Asked whether or not anything can send reminders: it decides what the
    # staleness report says, which is useful with no automation at all.
    while (1) {
        my $stuck = _ask( $in, 'Minutes before a card counts as stuck (blank for never)',
            $default->{notify_after} );
        return ( undef, 2 ) if !defined $stuck;
        last if $stuck eq '';
        if ( $stuck !~ /\A[0-9]+(?:\.[0-9]+)?\z/ || $stuck <= 0 ) {
            print "  That must be a positive number of minutes.\n";
            next;
        }
        $answers{notify_after} = $stuck;
        last;
    }

    # With no coding agent installed there is nothing to configure and nothing
    # that could deliver, so none of this is asked.
    if ( _agent_available('claude') ) {
        # TKT-459 already made project_update accept any registered, active
        # person as the agent - not only literally 'claude' - so a project
        # whose agent is genuinely someone else (its own example: 'zenbot')
        # can declare it here too. TKT-560: this question used to refuse
        # anything but 'claude', stale since that engine change shipped.
        my $agent = _ask( $in, 'Which coding agent should be reminded', $default->{agent} // 'claude' );
        return ( undef, 2 ) if !defined $agent;
        $answers{agent} = $agent if $agent ne '';
        while (1) {
            my $session = _ask( $in, 'Session id of the agent to remind', $default->{session} );
            return ( undef, 2 ) if !defined $session;
            last if $session eq '';
            if ( $session !~ /\A[A-Za-z0-9_-]{1,128}\z/ ) {
                print "  A session id is letters, digits, hyphens and underscores.\n";
                next;
            }
            $answers{session} = $session;
            last;
        }
        while (1) {
            my $collector = _ask( $in, 'Name for this project reminder job',
                $default->{collector} // Tira::_column_slug( $answers{name} ) );
            return ( undef, 2 ) if !defined $collector;
            last if $collector eq '';
            if ( $collector !~ /\A[a-z][a-z0-9-]{0,63}\z/ ) {
                print "  That must be lowercase letters, digits and hyphens.\n";
                next;
            }
            $answers{collector} = $collector;
            last;
        }
    }

    # One number of minutes, not two. The owner read the second as a repeat of
    # the first, and he was right to: there is no point looking more often than
    # the shortest window that could make anything stale. An explicit
    # --heartbeat still wins for anyone who wants to tune it.
    $answers{heartbeat} = $option->{heartbeat} // $answers{notify_after}
      if defined $answers{session}
      && defined( $option->{heartbeat} // $answers{notify_after} );

    # Which kind of project this is, asked rather than assumed. The questions
    # are the engine's, so what onboarding asks can be read by a test instead
    # of inferred from a sequence of prints. Left unanswered it stays unset,
    # and an unset project behaves exactly as every project does today.
    for my $question ( @{ $tira->onboarding_questions } ) {
        print "\n$question->{why}\n";
        while (1) {
            my $answer = _ask( $in, $question->{text}, $stored->{ $question->{id} } );
            return ( undef, 2 ) if !defined $answer;
            last if $answer eq '';
            if ( !grep { $_ eq $answer } @{ $question->{options} } ) {
                print '  Answer with ' . join( ' or ', @{ $question->{options} } ) . ".\n";
                next;
            }
            $answers{ $question->{id} } = $answer;
            last;
        }
    }

    print "\nAbout to create:\n";
    print "  name       $answers{name}\n";
    print "  directory  $answers{dir}\n";
    print "  people     " . ( join( ', ', @{ $answers{members} // [] } ) || '(none)' ) . "\n";
    print "  prefixes   sow $answers{sow_prefix}, epic $answers{epic_prefix}, ticket $answers{ticket_prefix}\n";
    for my $key ( grep { /_columns\z|\Acolumns\z/ } sort keys %answers ) {
        print "  $key " . join( ', ', @{ $answers{$key} } ) . "\n";
    }
    for my $key (qw(mode notify_after agent session collector heartbeat)) {
        print "  $key " . ( $answers{$key} // '(none)' ) . "\n" if exists $answers{$key};
    }
    print "\n";
    my $confirmed = _ask_yes( $in, 'Create this project?', 1 );
    return ( undef, 2 ) if !defined $confirmed;
    return ( undef, 1 ) if !$confirmed;
    return ( \%answers, 0 );
}

sub _attachment_content_type {
    my ($extension) = @_;
    return Tira::_attachment_content_type($extension);
}

# Who is doing this, for the work log, set once for whatever runs next.
#
# Every record write journals the change and stamps it with the author the
# engine happens to be holding, and only four methods ever set one. So a
# checklist item, a gate, a piece of evidence and an assignment were all written
# by nobody - and gate.add and evidence.add collected an author, stored it
# inside the entry, and did not use it here. A project spent two days on a card
# that appeared to move by itself, because a headless agent resuming their
# session moved it every fifteen minutes and the history could not say so.
#
# This is the layer that knows: it has already resolved --author, or TIRA_AUTHOR
# said once rather than on every command. The methods that validate the author
# themselves still do, and overwrite this with the same answer.
#
# A name the board does not know is not recorded. A log that writes down any
# name is worse than one that writes down none, because an unknown name reads as
# accounted for - and a command run before its project exists has nobody to be.
sub _journal_identity {
    my ( $tira, $args ) = @_;
    my $author = $args->{author};
    return undef if !defined $author || $author eq '';
    return eval {
        my $root = $tira->discover_project( %{$args} );
        $tira->_journal_attribution( project => $root, author => $author );
    };
}

# Whether a move would skip ahead in the board's own declared column order.
# Returns a refusal message naming the correct next column(s), or undef when
# the move is fine - backward (redoing work after a step back), sideways to
# the same column, or into discard, which is always exempt regardless of
# position: abandoning work is not skipping it. Measured against the owner's
# own example: chain backlog -> planning -> doc -> code, a move straight from
# backlog to code refuses naming planning. TKT-426.
#
# A column's next step is normally derived from array position, one value -
# correct for a linear chain, wrong at a genuine fork, where more than one
# column is a legitimate forward step and which one depends on the card's
# own path (owner's example: a chain ending 'e2e testing', which then forks
# to either 'done' or 'deploying'). A column carrying an explicit --next set
# (tira.column.update --next) is checked against that set instead of the
# single positional successor; a column with nothing configured keeps
# deriving its one next step from position, unchanged. TKT-430.
#
# A skip that would otherwise refuse is allowed anyway when every column
# strictly between the origin and the destination already carries a passing
# gate named exactly like that column - a naming convention, not a new
# mapping (owner's own answer, Q-053): nothing in Tira ties a gate name to a
# column, so the column's own name is the gate's name. A card whose
# intermediate stages already passed does not need a mechanical walk through
# columns it never substantively occupied - gate.add already exists to
# prove what happened, and the chain check should trust it. TKT-429.
sub _column_chain_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq ( $args{column} // '' );
    my $columns = eval { $tira->column_list(%args) };
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    my $from_idx = $index{$from};
    my $to_idx   = $index{ $args{column} };

    # Backward is always fine, fork or no fork.
    return undef if $to_idx <= $from_idx;

    my ($from_col) = grep { $_->{name} eq $from } @{$columns};
    my $fork = $from_col ? ( $from_col->{next} // [] ) : [];
    my $blocked;
    if ( @{$fork} ) {
        if ( !grep { $_ eq $args{column} } @{$fork} ) {
            my $options = join( ' or ', @{$fork} );
            $blocked = "Cannot move $args{ref} to $args{column} - the next column should be $options.\n"
              . "  Move there first, e.g.:  d2 tira.$args{type}.move --ref $args{ref} --column $fork->[0]\n";
        }
    }
    elsif ( $to_idx > $from_idx + 1 ) {
        my $next_name = $columns->[ $from_idx + 1 ]{name};
        $blocked = "Cannot move $args{ref} to $args{column} - the next column should be $next_name.\n"
          . "  Move there first:  d2 tira.$args{type}.move --ref $args{ref} --column $next_name\n";
    }
    return undef if !defined $blocked;

    my @log = @{ $current->{gate_passing_log} // [] };
    my $all_gated = 1;
    SKIPPED: for my $j ( $from_idx + 1 .. $to_idx - 1 ) {
        my $name = $columns->[$j]{name};
        next SKIPPED if grep { ( $_->{gate} // '' ) eq $name && ( $_->{result} // '' ) eq 'pass' } @log;
        $all_gated = 0;
        last SKIPPED;
    }
    return undef if $all_gated;
    return $blocked;
}

# A column names what must be done before a card leaves it (TKT-427); the
# move refuses, naming which of that column's required items are still
# unmarked, instead of the checklist item existing as a suggestion nobody is
# made to act on. discard is exempt, same as the chain check above and for
# the same reason: abandoning work is not leaving a stage undone. Checked in
# this same CLI-only dispatch layer - the dashboard's own move provider calls
# record_move directly and is untouched.
#
# Only a forward departure is checked. A backward move is how a card escapes
# a column it cannot currently satisfy - the unmet item may be exactly what
# failed, e.g. a test column's own 'tests green' - so gating retreat the same
# way as progress would leave a card with nowhere to go. This matches the
# chain check's own backward exemption.
sub _column_required_action_violation {
    my ( $tira, %args ) = @_;
    return undef if ( $args{column} // '' ) eq 'discard';
    my $current = eval { $tira->record_show(%args) };
    return undef if !$current;
    my $from = $current->{column};
    return undef if !defined $from || $from eq 'discard' || $from eq ( $args{column} // '' );
    my $columns = eval { $tira->column_list(%args) };
    return undef if ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return undef if !exists $index{$from} || !exists $index{ $args{column} };
    return undef if $index{ $args{column} } < $index{$from};

    # The column's template is a baseline, not an absolute: a card can carry
    # its own exemptions from specific items (tira.<type>.update
    # --exempt-required TEXT), for a situation the column-wide template does
    # not fit. Checked here rather than by the card silently omitting the
    # item, so the exemption is a decision on record, not an absence nobody
    # can tell from a genuine oversight. TKT-439.
    # An exemption recorded before TKT-473 is a bare string; one recorded
    # since carries {item, reason, exempted_at, author}. Both name the item
    # the same way to this check.
    my %exempt = map { ( ref($_) eq 'HASH' ? $_->{item} : $_ ) => 1 } @{ $current->{required_exempt} // [] };

    # Required items are their own list, tagged by the column they belong
    # to - not a card's checklist, which stays purely manual. Gating reads
    # this list directly rather than cross-referencing the column's live
    # template, so a card-specific item an agent added
    # (tira.required-action.add) gates exactly like a template-derived one -
    # it was never part of the column's template to begin with. TKT-445.
    # Status is free text, same as checklist - only the comparison against
    # "done" is case-insensitive, so --status Done is not read as still
    # outstanding and refused forever with a message that names the very
    # word the person already used. TKT-434.
    my @unmet = grep {
        ( $_->{column} // '' ) eq $from && !$exempt{ $_->{item} } && lc( $_->{status} // '' ) ne 'done';
    } @{ $current->{required_items} // [] };
    return undef if !@unmet;
    return "Cannot move $args{ref} out of $from - required actions not done: "
      . join( '; ', map { $_->{item} } @unmet ) . ".\n"
      . "  Mark them done, then move again:  d2 tira.required-action.update --ref $args{ref} --id REQ-NNN --status done\n";
}

# The other half of TKT-427, applied after a move succeeds: the destination
# column's required-action template is added to the card's checklist,
# skipping anything it already carries so re-entering a column never
# duplicates. A backward move resets to undone every required item belonging
# to a column from the new position through the old one, inclusive on both
# ends - owner's own example, EPC-002 comment 17:11:14: chain
# backlog->planning->doc->code->test->review, a card at test moved back to
# planning resets required items for test, code, doc AND planning itself,
# because redoing the work means every one of those checks - including the
# column landed on - needs satisfying again on the way back through. Until
# 3.13 the destination was excluded, so an item already done there stayed
# done even though the card was landing back on that exact column; the
# owner asked for it included (TG msg 4342). TKT-455. discard is excluded
# on both sides: its position in the declared column order is not a
# statement about how much work it undoes.
sub _populate_column_required_actions {
    my ( $tira, $args, $to, $columns, $required_items ) = @_;
    my ($to_col) = grep { $_->{name} eq $to } @{$columns};
    for my $text ( @{ $to_col->{required_actions} // [] } ) {
        next if grep { $_->{item} eq $text && $_->{column} eq $to } @{$required_items};
        $tira->required_item_add( %{$args}, item => $text, status => 'pending', column => $to, source => 'required-action' );
    }
    return;
}

sub _apply_column_required_actions {
    my ( $tira, $args, $from, $to, $columns, $record ) = @_;
    return
      if !defined $from || !defined $to || $from eq 'discard' || $to eq 'discard'
      || $from eq $to || ref $columns ne 'ARRAY';
    my %index;
    my $i = 0;
    for my $col ( @{$columns} ) { $index{ $col->{name} } = $i++; }
    return if !exists $index{$from} || !exists $index{$to};
    my $from_idx = $index{$from};
    my $to_idx   = $index{$to};

    # Required items live on their own list, each tagged with the column it
    # applies to (TKT-445) - not the card's checklist, which this mechanism
    # never touches again. Dedup and reset both match on (column, item)
    # rather than item text alone, so an identical required-action string
    # declared on two different columns can never be confused for one item.
    my @required_items = @{ $record->{required_items} // [] };

    if ( $to_idx > $from_idx ) {
        _populate_column_required_actions( $tira, $args, $to, $columns, \@required_items );
    }
    elsif ( $to_idx < $from_idx ) {
        my @reset;
        for my $item (@required_items) {
            next if !defined $item->{column} || !exists $index{ $item->{column} };
            my $item_idx = $index{ $item->{column} };
            next if $item_idx < $to_idx || $item_idx > $from_idx;

            # Same case-insensitive comparison as the move-out gate above -
            # an item marked --status Done is genuinely done, and must reset
            # on the way back through exactly as --status done would. TKT-434.
            next if lc( $item->{status} // '' ) ne 'done';
            $tira->required_item_update( %{$args}, id => $item->{id}, status => 'pending', source => 'required-action' );
            push @reset, $item->{item};
        }

        # A backward move-in is still a move-in: the destination column's own
        # template must be on the card even if it was never populated on an
        # earlier forward pass - which happens when the template was declared
        # after the card had already left that column once, exactly what
        # TKT-458 hit in practice. TKT-464.
        _populate_column_required_actions( $tira, $args, $to, $columns, \@required_items );

        # zen-framework's report (TKT-525): a card moved all the way back
        # into Backlog - always the structurally-first column, so this reset
        # is the most extreme case the branch above already handles - looked
        # broken because nothing said why a done item, proof intact, now
        # reads pending. The reset is correct (TKT-455); what was missing was
        # an explanation on the card itself. Michael's answer to Q-079: keep
        # the reset, add the comment. One comment per move, not one per item,
        # and only when something actually reset - a backward move that
        # resets nothing has nothing to explain.
        if (@reset) {
            eval {
                $tira->comment_add( %{$args},
                    text => "Moved backward from $from to $to: " . scalar(@reset)
                      . ' required item(s) reset to pending, proof kept - '
                      . join( ', ', @reset )
                      . '. This is the intended backward-move design (redoing work from here means every check between here and where you were needs satisfying again), not something undone by hand.',
                );
            };
        }
    }
    return;
}

sub _invoke {
    my ( $tira, $command, $record_type, $option ) = @_;
    # Who is running this, said once in the environment rather than remembered
    # on every command. Moves and edits from the command line went into the
    # work log attributed to nobody - the log knew what happened and never who,
    # which is most of what a work log is for. The browser has always known,
    # because there is a login in front of it. Absent both, the entry says
    # nobody rather than guessing at a name.
    if ( !defined $option->{author} && defined $ENV{TIRA_AUTHOR} && $ENV{TIRA_AUTHOR} ne '' ) {
        $option->{author} = utf8::is_utf8( $ENV{TIRA_AUTHOR} )
          ? $ENV{TIRA_AUTHOR} : decode( 'UTF-8', $ENV{TIRA_AUTHOR}, FB_CROAK );
    }

    # Before anything is dispatched, because a record command returns long
    # before the misleading-option table is reached and the whole point is that
    # nothing acts on an option it will not use.
    _refuse_unread_options( $command, $option );

    my %args = %{$option};
    delete @args{qw(output help apply repair_columns recursive include_deleted include_discard full dry_run attach set_key_details set_deliverables set_acceptance set_test_steps set_bdd set_atdd set_labels set_affects_versions set_scope_in set_scope_out field_selection exclude_fields include_empty older_than stale with_level all columns_json nested mark members columns sow_prefix epic_prefix ticket_prefix sow_columns epic_columns ticket_columns)};

    # Set here so every command carries it, rather than in each method that
    # writes - which is how only four of them ever did.
    local $tira->{_journal_author} = _journal_identity( $tira, \%args );
    if ( defined $option->{field_selection} || defined $option->{exclude_fields}
        || $option->{include_empty} || defined $option->{since}
        || $option->{brief} || defined $option->{truncate} ) {
        my $comment_scope = ( defined $option->{field_selection} || defined $option->{since} )
          && !defined $option->{exclude_fields} && !$option->{include_empty}
          && !$option->{brief} && !defined $option->{truncate};
        die "Read options are available on show, list, and export commands\n"
          if $command !~ /\A(?:record\.(?:show|list)|export|next)\z/
          && !( $comment_scope && $command =~ /\A(?:comment\.list|attachment\.list|diff)\z/ );
        $args{fields} = $option->{field_selection} if defined $option->{field_selection};
        $args{exclude_fields} = $option->{exclude_fields} if defined $option->{exclude_fields};
    }
    if ( $command =~ /\A(?:record\.(?:show|list)|export|history\.list)\z/ ) {
        die "Cannot combine --full with --truncate\n"
          if $option->{full} && defined $option->{truncate};
        die "Truncate must be zero or a positive character count\n"
          if defined $option->{truncate} && $option->{truncate} < 0;
        $args{truncate} = defined $option->{truncate} ? $option->{truncate}
          : $option->{full} ? undef : 2000;
        delete $args{truncate} if !defined $args{truncate};
    }
    $args{omit_empty} = 1
      if $command =~ /\A(?:record\.(?:show|list)|export)\z/ && !$option->{include_empty};
    delete $args{omit_empty} if $command eq 'history.list';
    die "Conditional reads are available on show and export commands\n"
      if defined $option->{if_changed} && $command !~ /\A(?:record\.show|export)\z/;
    die "Count is available on list, export, and search commands, and the comment, attachment, gate, and evidence lists\n"
      if $option->{count} && $command !~ /\A(?:record\.list|export|search|comment\.list|attachment\.list|gate\.list|evidence\.list|history\.list|diff)\z/;
    die "Snapshot baselines are available on the diff command\n"
      if defined $option->{snapshot} && $command ne 'diff';
    die "Older-than is available on the stale command\n"
      if defined $option->{older_than} && $command ne 'stale';
    die "Stale is available on the stale command\n"
      if $option->{stale} && $command ne 'stale';
    die "With-level is available on the stale command\n"
      if $option->{with_level} && $command ne 'stale';
    # Accepted and ignored is the worst of the three outcomes. An error is
    # fixed in seconds; doing the work would be right; answering with a
    # successful record while doing nothing cost this project every ticket's
    # parent and was invisible until somebody looked at a card.
    #
    # create is not refused here any more (TKT-362): at create time there is
    # no ref yet, so this message's own advice printed the unrunnable
    # placeholder "<this record>". create_record does the link itself and
    # applies hierarchy_link's own validation, so a bad parent still fails -
    # just with a message that names something that exists.
    if ( defined $option->{parent} && $command =~ /\A(?:record|sow|epic|ticket)\.update\z/ ) {
        my $child = $option->{ref} // '<this record>';
        die "A parent is set with hierarchy.link, not by updating the record:\n"
          . "  tira.hierarchy.link --parent $option->{parent} --child $child\n";
    }

    die "All is available on the warning.clear and login.logout commands\n"
      if $option->{all} && $command ne 'warning.clear' && $command ne 'login.logout';
    die "A password belongs to the login.register and login.check commands\n"
      if defined $option->{password} && $command !~ /\Alogin\.(?:register|check)\z/;
    die "A column layout belongs to the column.apply command\n"
      if defined $option->{columns_json} && $command ne 'column.apply';
    die "Nested belongs to the project.new, project.create and onboard commands\n"
      if $option->{nested} && $command !~ /\A(?:project\.(?:new|create)|onboard)\z/;
    die "A mark belongs to the question.mark command\n"
      if defined $option->{mark} && $command ne 'question.mark';
    die "A reason and options belong to the question.ask and question.update commands, "
      . "to police.suspend, to rule.suspend, to policy.decline, and to column.roles "
      . "when it takes a role back\n"
      if ( defined $option->{reason} || $option->{options} )
      && $command !~ /\Aquestion\.(?:ask|update)\z/
      && $command ne 'police.suspend'
      && $command ne 'rule.suspend'
      && $command ne 'policy.decline'
      && $command ne 'column.roles';
    die "A voice note belongs to the question.ask, question.update and question.voice commands\n"
      if defined $option->{voice} && $command !~ /\Aquestion\.(?:ask|update|voice)\z/;
    die "Remove belongs to the question.voice and question.attach commands\n"
      if $option->{remove} && $command !~ /\Aquestion\.(?:voice|attach)\z/;
    die "Naming a question belongs to the attachment.list command\n"
      if $option->{questions} && $command ne 'attachment.list';
    # notify.moves reads it too, and adding the verb without widening this made
    # the whole per-column switch unreachable: every --watch it was documented
    # to take was refused before it was dispatched. The guard that exists to
    # stop an option being silently dropped had instead stopped it being given.
    die "Watch is available on the column.update and notify.moves commands\n"
      if defined $option->{watched} && $command !~ /\A(?:column\.update|notify\.moves)\z/;
    die "Queue is available on the column.update command\n"
      if defined $option->{queue} && $command ne 'column.update';
    die "Required-action is available on the column.update command\n"
      if defined $option->{required_action} && $command ne 'column.update';
    die "Next is available on the column.update command\n"
      if defined $option->{next} && $command ne 'column.update';
    die "Notify-after is available on the column.update, project.update, project.new and onboard commands\n"
      if defined $option->{notify_after}
      && $command !~ /\A(?:column\.update|project\.update|project\.new|onboard)\z/;

    # --column is the reflex flag on record.move, record.list, notify.record
    # and search - the one every other command on this board takes. The four
    # commands that identify a column itself name it with --name instead, and
    # --column was accepted by option parsing (it is a real flag, just for a
    # different command) and then silently ignored: column.update --column X
    # updated nothing named by --column, and with --name absent entirely it
    # died "Column '' not found" - a specific, false claim about the board
    # when the actual fault was the reflex flag. TKT-305.
    die "This command identifies a column with --name, not --column\n"
      if defined $option->{column} && $command =~ /\Acolumn\.(?:add|update|rename|remove)\z/;
    # --session is also the tasklist commands' own scoping flag (TKT-504) -
    # a different meaning on a different feature, not a project reminder
    # setting, so tasklist.* is exempt from this guard same as the three
    # project commands are. The nested task.attach/ref sub-verbs
    # (tasklist.task.attach.add, .discard, .ref.link, .ref.unlink) are
    # dotted four deep, not two - tasklist\.[a-z]+ never matched them, so
    # --session was refused on exactly the commands TKT-538 needed it most
    # on, since those are the ones that mutate an existing item by id.
    die "Reminder settings belong to the project.update, project.new and onboard commands\n"
      if $command !~ /\A(?:project\.update|project\.new|onboard|tasklist\.[a-z](?:[a-z.]*[a-z])?)\z/
      && grep { defined $option->{$_} } qw(collector agent heartbeat);

    # --session is not a reminder setting, and grouping it with three that are
    # is what refused it on search. Both documents describe search's tasklist
    # matching as "scoped to the caller's own --session ... exactly as
    # tasklist.list is" - and it was, in the engine, reachable only through
    # TIRA_AGENT_SESSION because the flag itself was rejected here with a
    # message naming three commands, none of them the one typed.
    #
    # Given its own guard rather than another name appended to that one: the
    # comment above records this whitelist being patched once already for the
    # same class of miss (tasklist's four-deep sub-verbs matched by a
    # two-level pattern), and a scoping argument sharing a list with
    # collector/agent/heartbeat will keep collecting these. TKT-580.
    die "A session scopes the tasklist, search and project commands\n"
      if defined $option->{session}
      && $command !~ /\A(?:project\.update|project\.new|onboard|search|tasklist\.[a-z](?:[a-z.]*[a-z])?)\z/;
    die "Dashboard address options belong to the project.update command\n"
      if $command ne 'project.update'
      && grep { defined $option->{$_} } qw(dashboard_host dashboard_port listen);
    if ( defined $option->{listen} ) {
        # The compact form the owner asked for: --listen any:8080 is the same
        # thing as --dashboard-host any --dashboard-port 8080.
        my ( $host, $port ) = $option->{listen} =~ /\A([^:]+)(?::([0-9]+))?\z/
          or die "Listen address must be HOST or HOST:PORT\n";
        $args{dashboard_host} = $host;
        $args{dashboard_port} = $port if defined $port;
    }
    delete $args{listen};
    die "Bootstrap options belong to the project.new command\n"
      if $command ne 'project.new'
      && $command ne 'onboard'
      && grep { defined $option->{$_} }
      qw(members columns sow_columns epic_columns ticket_columns
         sow_prefix epic_prefix ticket_prefix);
    if ( defined $option->{cache_ttl} || $option->{no_cache} ) {
        die "Caching is available on read commands only\n"
          if $command !~ /\A(?:record\.(?:show|list)|export|search|diff|board\.show|project\.show|(?:comment|attachment|gate|evidence|checklist)\.list)\z/;
        die "Cache TTL must be a positive number of seconds\n"
          if defined $option->{cache_ttl} && $option->{cache_ttl} < 1;
    }
    delete @args{qw(cache_ttl no_cache)};
    die "Windows (--last/--first) are available on the comment, gate, evidence, and history lists\n"
      if ( defined $option->{last} || defined $option->{first} )
      && $command !~ /\A(?:comment|gate|evidence|history)\.list\z/;
    die "Meta-only is available on the comment and attachment lists, gate and evidence lists, show, list, and export\n"
      if $option->{meta_only}
      && $command !~ /\A(?:comment\.list|attachment\.list|gate\.list|evidence\.list|record\.(?:show|list)|export)\z/;
    die "Where filtering is available on list and export commands, and the gate and evidence lists\n"
      if defined $option->{where} && $command !~ /\A(?:record\.list|export|gate\.list|evidence\.list|history\.list)\z/;
    my @batch_refs = (
        @{ $option->{ref_list} // [] } > 1 ? @{ $option->{ref_list} } : (),
        defined $option->{refs} ? ( split /,/, $option->{refs} ) : (),
    );
    if (@batch_refs) {
        die "Multiple refs are only available on show\n"
          if $command !~ /\A(?:record\.show|tasklist\.next|release\.record)\z/;
        die "Conditional reads do not batch; poll with export --fields ref,content_hash instead\n"
          if defined $option->{if_changed};
        @batch_refs = ( @{ $option->{ref_list} // [] }, @batch_refs )
          if @{ $option->{ref_list} // [] } == 1 && defined $option->{refs};
        $args{refs} = \@batch_refs;
        delete $args{ref};
        delete $args{ref_list};
    }
    delete $args{ref_list};
    delete $args{refs} if !@batch_refs;
    die "Refs-only is available on list and search commands\n"
      if $option->{refs_only} && $command !~ /\A(?:record\.list|search)\z/;
    $args{type} = $record_type if defined $record_type;
    my %sets = (
        set_key_details => 'key_details_replace', set_deliverables => 'deliverables_replace',
        set_acceptance => 'acceptance_replace', set_test_steps => 'test_steps_replace',
        set_bdd => 'bdd_replace', set_atdd => 'atdd_replace',
        set_labels => 'labels_replace', set_affects_versions => 'affects_versions_replace',
        set_scope_in => 'scope_in_replace', set_scope_out => 'scope_out_replace',
    );
    for my $set ( keys %sets ) {
        next if !defined $option->{$set};
        my $append = $set eq 'set_labels' ? 'labels'
          : $set eq 'set_affects_versions' ? 'affects_versions'
          : $set eq 'set_scope_in' ? 'scope_in'
          : $set eq 'set_scope_out' ? 'scope_out'
          : $sets{$set} =~ s/_replace\z//r;
        die "Cannot combine append and replacement for '$append'\n" if defined $args{$append};
        $args{ $sets{$set} } = _json_array_input( $option->{$set} );
    }
    $args{label} = $option->{labels}[0] if $command =~ /\Acolumn\.(?:add|rename)\z/ && $option->{labels};

    return $tira->create_project( name => $option->{name}, dir => $option->{dir} // '.' ) if $command eq 'project.create';
    if ( $command eq 'project.new' || $command eq 'onboard' ) {

        # Before anything is written, not after. project_mode is called below
        # once the project exists, and it refuses anything but its two values
        # - which used to mean an invalid --mode produced a failed command AND
        # a fully created project, with nothing to roll back and nothing
        # saying so. "It failed" and "it half worked" are different facts, and
        # only one of them tells the reader to go and look at the directory;
        # the next attempt then meets a project that should not be there.
        #
        # The wizard's own loop already re-asks against these same options, so
        # ordinary interactive use never got here. What did was the --mode
        # flag on project.new, and the browser onboarding form, whose mode
        # field renders its options as a hint and validates nothing before
        # calling back into this dispatch. Checking here covers both, because
        # both arrive here.
        #
        # The options come from onboarding_questions() rather than a literal
        # pair, so a third mode cannot be added there and silently refused
        # here. TKT-562.
        if ( defined $option->{mode} ) {
            my ($question) = grep { $_->{id} eq 'mode' } @{ $tira->onboarding_questions };
            my @allowed = @{ $question->{options} // [] };
            die "--mode must be one of: " . join( ', ', @allowed ) . "\n"
              if @allowed && !grep { $_ eq $option->{mode} } @allowed;
        }

        my $summary = $tira->project_new(
            name => $option->{name}, dir => $option->{dir} // '.',
            members => $option->{members}, columns => $option->{columns},
            map( { ( "${_}_columns" => $option->{"${_}_columns"} ) }
                grep { defined $option->{"${_}_columns"} } qw(sow epic ticket) ),
            ( defined $option->{digits} ? ( digits => $option->{digits} ) : () ),
            map( { ( "${_}_prefix" => $option->{"${_}_prefix"} ) }
                grep { defined $option->{"${_}_prefix"} } qw(sow epic ticket) ),
            map( { ( $_ => $option->{$_} ) }
                grep { defined $option->{$_} } qw(notify_after collector agent session heartbeat) ),
            ( $option->{nested} ? ( nested => 1 ) : () ),
        );

        # Written after the project exists, because it is a fact about the
        # project rather than one of the things that makes one. Unanswered
        # leaves it unset, and unset is every board that exists today.
        $tira->project_mode( project => $option->{dir} // '.', mode => $option->{mode} )
          if defined $option->{mode};

        # Collecting the settings and leaving the job unregistered
        # looked like it had worked. Onboarding registers it, and reports the
        # name it will really answer to, which is not the name that was typed.
        if ( $command eq 'onboard' && defined $summary->{project}{heartbeat} ) {
            # Project_show carries no root, so use the directory that was created.
            my $job = eval { $tira->collector_install( project => $option->{dir} // '.' ) };
            if ($job) {
                print "\nRegistered the reminder job as '$job->{name}'.\n"
                  . "Start it with: dashboard collector start $job->{name}\n\n";
                $summary->{collector} = $job;
            }
        }
        return $summary;
    }
    if ( $command eq 'question.attach' ) {
        return $tira->question_attach(
            project => $args{project}, id => $option->{id},
            file => $option->{file}, to => $option->{to},
            filename => $option->{filename}, remove => $option->{remove} );
    }
    if ( $command eq 'question.voice' ) {
        my $path = $option->{file} // $option->{voice};
        die "Use only one of --file or --remove\n" if defined $path && $option->{remove};
        return $tira->question_voice(
            project => $args{project}, id => $option->{id},
            file => $path, remove => $option->{remove} );
    }
    if ( $command =~ /\Aquestion\.(ask|list|answer|update|mark|discard)\z/ ) {
        my $action = $1;

        # By card reference alone: the reference already names the board, so
        # asking for the board as well would be asking for what is known.
        my %question = ( project => $args{project} );
        $question{ref} = $option->{ref_list}[0] if $option->{ref_list};
        $question{$_} = $option->{$_} for grep { defined $option->{$_} } qw(id text mark author reason);
        # ask as well as update. The option was accepted, refused on every
        # command it does not belong to - "A voice note belongs to the
        # question.ask, question.update and question.voice commands" - and then
        # passed through for update alone, so asking with a recording produced a
        # question whose own reminder told its author to supply the recording
        # they had just supplied. question_add has always attached it, after the
        # question exists so a bad recording fails the voice rather than the
        # question, and the manual has always documented it. Only this line
        # disagreed.
        $question{voice} = $option->{voice}
          if defined $option->{voice} && ( $action eq 'update' || $action eq 'ask' );
        $question{file} = $option->{file} if defined $option->{file} && $action eq 'answer';
        $question{options} = $option->{options} if $option->{options};
        $question{status} = $option->{status} if defined $option->{status};
        $question{since} = $option->{since} if defined $option->{since};
        die "Peek is available on the question.list command\n"
          if $option->{peek} && $action ne 'list';
        $question{peek} = 1 if $option->{peek};
        return $tira->question_add(%question) if $action eq 'ask';
        return $tira->question_list(%question) if $action eq 'list';
        return $tira->question_answer(%question) if $action eq 'answer';
        return $tira->question_update(%question) if $action eq 'update';
        return $tira->question_discard(%question) if $action eq 'discard';
        return $tira->question_mark(%question);
    }
    # Reports by default and writes only when asked. History is the permanent
    # record of a board, and a record somebody's tooling quietly rewrites is not
    # evidence any more - so the repair is a flag somebody types, not a default.
    return $tira->doctor( %args, ( $option->{repair} ? ( repair => 1 ) : () ) )
      if $command eq 'doctor';

    return $tira->warning_list(%args) if $command eq 'warning.list';
    return $tira->warning_add(%args) if $command eq 'warning.add';
    return $tira->warning_clear( %args, all => $option->{all} ) if $command eq 'warning.clear';
    return $tira->notification_message( project => $args{project} ) if $command eq 'notify.compose';
    return $tira->collector_entry(%args) if $command eq 'collector.show';
    return $tira->collector_install(%args) if $command eq 'collector.install';
    return $tira->collector_remove(%args) if $command eq 'collector.remove';
    if ( $command =~ /\Anotify\.(record|list)\z/ ) {
        my $action = $1;
        my %notify = ( project => $args{project}, ref => $option->{ref_list} );
        $notify{column} = $option->{column} if defined $option->{column};
        return $tira->notification_list(%notify) if $action eq 'list';
        return $tira->notification_record(%notify);
    }
    if ( $command eq 'record.create' ) {

        # A card created directly into implement, or verify, or done never
        # needs the move TKT-426's chain check would refuse - reusing the
        # existing column-roles vocabulary ('which column is the backlog' is
        # already a role every board can answer) rather than a new mechanism.
        # Checked here, in the dispatch layer, so create_record itself - and
        # the dashboard's own create flow, which calls it directly - is
        # untouched. TKT-428.
        my $entry = eval { $tira->column_roles(%args) }->{entry};

        # 'entry' may now name more than one column (TKT-496) - a board can
        # start new cards in more than one place. Normalised to a list here
        # so the single-entry case (still the common one) needs no branch of
        # its own: with exactly one entry, this behaves exactly as before -
        # the same column either matches or is refused.
        my @entries = ref $entry eq 'ARRAY' ? @{$entry} : ( defined $entry && $entry ne '' ? ($entry) : () );
        if (@entries) {
            if ( defined $args{column} && $args{column} ne '' ) {
                die "Cannot create $args{type} in $args{column} - the entry column"
                  . ( @entries > 1 ? 's are ' . join( ', ', @entries ) : ' is ' . $entries[0] ) . ".\n"
                  . "  Create there instead:  d2 tira.$args{type}.create --title TITLE --column $entries[0]\n"
                  if !grep { $_ eq $args{column} } @entries;
            }
            else {
                # No column named: the first declared entry column, which is
                # exactly today's only entry column when there is just one -
                # nothing changes for a board that has never declared more.
                $args{column} = $entries[0];
            }
        }

        # A card landing in a column that carries required_actions needs an
        # author for the required_item_add calls below - and until now that
        # was discovered only by getting there: create_record has no author
        # requirement of its own (hundreds of test fixtures and the
        # dashboard's own create flow rely on that), so the record was
        # already written by the time required_item_add's own author check
        # died, leaving an orphaned, unattributed card on disk that a retry
        # with --author then duplicated rather than completed. Checked here,
        # before anything is written, using whichever column the card is
        # actually about to land in - entry role or explicit --column,
        # falling back to the same 'backlog' default create_record itself
        # uses. TKT-485.
        if ( !defined $args{author} || $args{author} eq '' ) {
            my $landing = defined $args{column} && $args{column} ne '' ? $args{column} : 'backlog';
            my $columns = eval { $tira->column_list(%args) };
            if ( ref $columns eq 'ARRAY' ) {
                my ($about_to_land) = grep { $_->{name} eq $landing } @{$columns};
                die "A change needs to say who is making it\n"
                  if $about_to_land && @{ $about_to_land->{required_actions} // [] };
            }
        }

        # The record itself stays exactly what is stored - an agent can trust
        # that what it holds is what is on disk. The advice about it belongs to
        # the layer that talks to agents, not to the data.
        my $created = $tira->create_record(%args);

        # Where it landed, read from the board rather than repeated from the
        # request. --column used to be accepted and discarded, and a create that
        # cannot say where the card is is how three projects came to believe
        # theirs were somewhere they had never been. Asking the board means the
        # answer cannot drift from the truth the way a second copy of the
        # default would.
        # Only what finds the card. Passing the whole request would hand it the
        # caller's --fields as well, and a create that asked for two fields
        # would come back with no column at all.
        my $column = $tira->record_show(
            ref => $created->{ref},
            ( defined $args{project} ? ( project => $args{project} ) : () ),
        )->{column};

        # A column's required-action template is populated on every move-in
        # (TKT-427), but creation is not a move, so a card landing directly
        # in its entry column - or any column carrying required_actions -
        # never received them. Populated here, mirroring the same move-in
        # logic exactly, into the card's own required_items list, tagged with
        # this landing column (TKT-445, not checklist); the dashboard's own
        # create flow, calling create_record directly, is untouched. TKT-439.
        my $columns = eval { $tira->column_list(%args) };
        if ( ref $columns eq 'ARRAY' ) {
            my ($landed) = grep { $_->{name} eq $column } @{$columns};
            my @required = @{ $landed->{required_actions} // [] };
            if (@required) {
                $tira->required_item_add( %args, ref => $created->{ref},
                    item => $_, status => 'pending', column => $column, source => 'required-action' )
                  for @required;

                # $created was captured before these writes; re-read so what
                # the caller sees is what is actually stored, the same
                # discipline record.move's own return already holds to.
                $created = $tira->record_show(
                    ref => $created->{ref},
                    ( defined $args{project} ? ( project => $args{project} ) : () ),
                );
            }
        }

        my $reminder = $tira->record_reminder($created);
        return { %{$created}, column => $column,
            ( defined $reminder ? ( reminder => $reminder ) : () ) };
    }
    return $tira->export_records(%args) if $command eq 'export';
    return $tira->diff_records(%args) if $command eq 'diff';
    if ( $command eq 'stale' ) {
        my %dwell = ( project => $args{project} );
        $dwell{type} = $args{type} if defined $args{type};
        $dwell{older_than} = $option->{older_than} if defined $option->{older_than};
        $dwell{stale} = 1 if $option->{stale};
        $dwell{with_level} = 1 if $option->{with_level};
        return $tira->dwell_list(%dwell);
    }
    if ( $command eq 'dwell.report' ) {
        my %dwell = ( project => $args{project} );
        $dwell{type} = $args{type} if defined $args{type};
        return $tira->dwell_report(%dwell);
    }
    if ( $command eq 'check.owner' ) {
        return $tira->check_owner( project => $args{project}, ref => $args{ref} );
    }
    if ( $command eq 'card.holes' ) {
        my %holes = ( project => $args{project} );
        $holes{type} = $args{type} if defined $args{type};
        return $tira->card_holes(%holes);
    }
    if ( $command eq 'history.list' ) {
        my %history = %args;
        delete $history{fields};
        $history{field} = $option->{fields}[0] if $option->{fields};
        return $tira->history_list(%history);
    }
    if ( $command eq 'import' ) {
        die "Import file is required\n" if !defined $option->{file};
        my $changes = Tira::json_decode( _text_input( $option->{file} ) );
        return $tira->bulk_import( %args, changes => $changes, dry_run => $option->{dry_run} );
    }
    return $tira->changelog_check(%args) if $command eq 'changelog.check';
    return $tira->replace_records( %args, dry_run => $option->{dry_run} ) if $command eq 'replace';
    return $tira->project_show(%args) if $command eq 'project.show';

    # Reading and setting are one command, because the answer is one fact and
    # two commands would invite a board where it was set and never read.
    return { mode => $tira->project_mode(%args) } if $command eq 'project.mode';
    return { max => $tira->project_limit(%args) } if $command eq 'project.limit';
    if ( $command eq 'project.gates' ) {
        return { gates => $tira->project_gates(%args) } if !$option->{gate_names};
        return { gates => $tira->project_gates_set( %args, names => $option->{gate_names} ) };
    }
    return $tira->conversation_add(%args) if $command eq 'conversation.add';
    return $tira->conversation_list(%args) if $command eq 'conversation.list';
    return $tira->agent_sessions(%args) if $command eq 'agent.sessions';
    return $tira->project_update(%args) if $command eq 'project.update';
    return $tira->person_list(%args) if $command eq 'project.people.list';
    return $tira->person_add(%args) if $command eq 'project.people.add';
    return $tira->person_update(%args) if $command eq 'project.people.update';
    return $tira->person_remove(%args) if $command eq 'project.people.remove';
    return $tira->person_activate(%args) if $command eq 'project.people.activate';
    return $tira->person_deactivate(%args) if $command eq 'project.people.deactivate';
    return $tira->link_type_list(%args) if $command eq 'project.link-types.list';
    return $tira->link_type_add(%args) if $command eq 'project.link-types.add';
    return $tira->link_type_remove(%args) if $command eq 'project.link-types.remove';
    return $tira->project_validate( %args, repair => $option->{repair_columns} ) if $command eq 'project.validate';
    return $tira->board_show(%args) if $command eq 'board.show';
    return $tira->board_refs(%args) if $command eq 'board.refs';
    return $tira->column_list(%args) if $command eq 'column.list';
    return $tira->column_add(%args) if $command eq 'column.add';
    return $tira->column_rename(%args) if $command eq 'column.rename';
    return $tira->column_reorder(%args) if $command eq 'column.reorder';
    return $tira->column_remove(%args) if $command eq 'column.remove';
    return $tira->column_update(%args) if $command eq 'column.update';

    # Telling the owner a card moved, set once by the agent. His words: a
    # police sentry rather than an agent sentry, so the notifying costs no
    # tokens. TKT-349.
    if ( $command eq 'notify.moves' ) {

        # A bare call is a read, not "turn it on" - defaulting enabled to 1
        # here made every plain d2 tira.notify.moves look, to the engine, like
        # --watch had been given. Only pass it when something was actually
        # named. TKT-398.
        return $tira->notify_moves(
            project => $args{project},
            ( defined $option->{column} ? ( column => $option->{column} ) : () ),
            ( defined $option->{chat} ? ( chat => $option->{chat} ) : () ),
            ( defined $option->{watched} ? ( enabled => $option->{watched} ) : () ),
        );
    }
    if ( $command eq 'column.apply' ) {
        my $layout = eval { Tira::json_object()->utf8->decode( $option->{columns_json} // '' ) };
        die "A column layout must be JSON: a list of objects with a name\n" if ref $layout ne 'ARRAY';
        return $tira->column_apply( project => $args{project}, type => $args{type}, columns => $layout );
    }
    return $tira->column_sync( %args, apply => $option->{apply} ) if $command eq 'column.sync';

    if ( $command eq 'column.roles' ) {

        # Taking one back, which nothing could do - a role declared by mistake
        # was permanent and undoing it meant editing .tira by hand. TKT-384.
        # The reason is required by the engine and belongs to the removal alone:
        # accepted-and-ignored beside a --role would be a stored explanation for
        # something nobody could later find.
        die "A reason belongs to --remove-role. Declaring a role does not take one\n"
          if defined $option->{reason} && !$option->{remove_roles};
        return $tira->column_roles_remove( %args, roles => $option->{remove_roles},
            reason => $option->{reason}, author => $option->{author} )
          if $option->{remove_roles};
        return $tira->column_roles(%args) if !$option->{roles};

        # Written the way he says it: which column is the backlog, which is
        # in progress. Each --role takes name=column, and any role may be
        # left unset because most projects have a column for very few of them.
        #
        # 'entry' alone may be given more than once - a board can start new
        # cards in more than one place - and repeating it accumulates rather
        # than the last one silently winning, the way a second --role of any
        # other name still does. TKT-496.
        my %roles;
        for my $pair ( @{ $option->{roles} } ) {
            my ( $role, $column ) = split /=/, $pair, 2;
            die "A role is written as name=column, not '$pair'\n"
              if !defined $column || $column eq '' || $role eq '';
            if ( $role eq 'entry' ) {
                push @{ $roles{$role} }, $column;
            }
            else {
                $roles{$role} = $column;
            }
        }
        return $tira->column_roles_set( %args, roles => \%roles );
    }

    if ( $command =~ /\Arecord\.(show|list|update|move|discard|restore|clone|missing)\z/ ) {
        my $action = $1;

        return $tira->record_missing(%args) if $action eq 'missing';

        # question.list computes a question's status (new/answered/discarded)
        # through Tira's own _question_view; record_show/record_show_many
        # return the stored entry as-is, which carries no status key at all -
        # a discarded question and a live one were distinguishable only by
        # discarded_at, invisible to a caller filtering on the documented
        # field. Applied here, at the CLI boundary, rather than inside
        # record_show itself: record_show is reused internally (by
        # question_update and others) as a fetch-then-mutate primitive, and a
        # view-shaped record fed back into _replace_record would write the
        # computed fields into storage. TKT-322.
        if ( $action eq 'show' && $args{refs} ) {
            my $result = $tira->record_show_many(%args);
            for my $record ( values %{ $result->{records} } ) {
                next if ref $record->{questions} ne 'ARRAY';
                $record->{questions} = [ map { Tira::_question_view($_) } @{ $record->{questions} } ];
            }
            return $result;
        }
        if ( $action eq 'show' ) {
            my $record = $tira->record_show(%args);
            $record->{questions} = [ map { Tira::_question_view($_) } @{ $record->{questions} } ]
              if ref $record->{questions} eq 'ARRAY';
            return $record;
        }
        return $tira->record_list(%args) if $action eq 'list';
        return $tira->record_update(%args) if $action eq 'update';
        if ( $action eq 'move' ) {

            # The CLI/agent path only - checked here, in the dispatch layer,
            # rather than inside record_move itself, so a direct engine call
            # (the browser dashboard's own move provider in browser_providers
            # calls record_move directly, never through here) is untouched.
            # The owner's own instruction: a human on the dashboard is not an
            # agent skipping a gate. TKT-426.
            my $blocked = _column_chain_violation( $tira, %args );
            die $blocked if defined $blocked;
            my $action_blocked = _column_required_action_violation( $tira, %args );
            die $action_blocked if defined $action_blocked;

            my $before  = eval { $tira->record_show(%args) };
            my $from    = $before ? $before->{column} : undef;
            my $result  = $tira->record_move(%args);
            my $columns = eval { $tira->column_list(%args) };
            _apply_column_required_actions( $tira, \%args, $from, $args{column}, $columns, $result )
              if ref $columns eq 'ARRAY';

            # Re-read rather than returning $result as-is: the required-action
            # population/reset above writes to the checklist after record_move
            # already captured its snapshot, so the caller's own output would
            # otherwise show the move without the side effect it just caused.
            return $tira->record_show(%args);
        }
        return $tira->record_discard(%args) if $action eq 'discard';
        return $tira->record_restore(%args) if $action eq 'restore';
        return $tira->record_clone(%args);
    }

    return $tira->gates_install(%args) if $command eq 'gates.install';
    return $tira->work_log(%args) if $command eq 'worklog.show';

    # policy.bridge.logs is the name; police.log is what it was called until
    # 1.41 and still answers, because renaming a shipped command breaks every
    # board that used it. tira.police runs the owner's watching loop and this
    # reads what that loop wrote - they shared a prefix and nothing else, which
    # cost another project's agent three corrections and, in between, every
    # suspension and escalation it should have been reading.
    if ( $command eq 'rule.suspend' ) {
        my $store = $option->{store}
          // _police_store( $tira->discover_project(%args) );
        return $tira->rule_suspend( %args, store => $store,
            rule => $option->{rule}, seconds => $option->{seconds},
            reason => $option->{reason},
            ( defined $option->{pid} ? ( pid => $option->{pid} ) : () ) );
    }

    # The definition of a complete card, for anything that is not this program.
    # The engine owns it; the push gate is python and cannot share a variable,
    # so it asks. TKT-241.
    if ( $command eq 'column.endings' ) {
        return $tira->column_endings(%args);
    }
    if ( $command eq 'card.required' ) {
        return Tira->card_required;
    }

    # What to pick up, from the board that already decided it. The ordering
    # belongs to priority-skipped, so it is asked rather than sorted again -
    # the rule and this command cannot give different answers. Reading every
    # card and sorting by hand was 1.95 MB of JSON on this project's own board
    # to find the eleven that were waiting. TKT-274.
    if ( $command eq 'next' ) {
        my $order = $tira->work_order( %args,
            ( $option->{brief} ? ( brief => 1 ) : () ),
            ( defined $option->{truncate} ? ( truncate => $option->{truncate} ) : () ) );

        # A quiet board used to answer with a bare array while a busy one
        # answered with {next, then} - the same command returning two
        # different TYPES depending on state. A caller written against the
        # documented shape does result->{next}, which works every time the
        # board has work and raises an error the first time it goes quiet -
        # precisely when a scheduled caller runs unattended and nobody is
        # watching. One shape now serves both states: next is undef rather
        # than an object when nothing is waiting, and the empty answer stays
        # just as unambiguous. TKT-354.
        return { next => undef, then => [] } if !@{$order};

        # The first one is the answer; the rest are what it was chosen over,
        # which is the part that makes the answer checkable rather than taken
        # on trust.
        return { next => $order->[0], then => [ @{$order}[ 1 .. $#{$order} ] ] };
    }

    # What is still true, rather than everything that ever happened. The bridge
    # is a stream and the log is flat, so neither could answer it and the answer
    # depended on somebody remembering to look. TKT-237.
    if ( $command eq 'police.outstanding' ) {
        my $store = $option->{store}
          // _police_store( $tira->discover_project(%args) );

        # A read, by default - fast, and answering from whatever the watcher
        # last wrote. --fresh runs the same pass the watcher would, inline,
        # before reading: fixing a violation and asking right away used to
        # mean it could still read as open for up to the watcher's own
        # interval (30s by default), because nothing had told the ledger the
        # fix happened. The loop that clears outstanding violations asks this
        # after every fix, so a stale answer here reads as "still broken" when
        # the truth is "not yet asked again". TKT-423.
        if ( $option->{fresh} ) {
            my $watching = $tira->discover_project(%args);
            my $result = $tira->police_pass( %args, store => $store,
                world => _police_world( tira => $tira, project => $watching ) );
            $tira->bridge_write( store => $store, project => $watching,
                violations => $result->{violations}, settled => $result->{settled},
                upgraded => $result->{upgraded} )
              if $result->{watching};
        }
        my $open = $tira->police_outstanding( %args, store => $store );

        # What was actually found, said before the answer is dressed up. The
        # exit status used to be taken from the rendered rows, which was true
        # only while a command's output WAS its findings - 2.62 gave this
        # command a summary and a clean board started exiting 1, saying "No
        # violations outstanding" and signalling that there were some. A
        # command that knows its count says so; rendering cannot move the
        # signal afterwards. TKT-385.
        $option->{findings_count} = scalar @{$open};

        # -o json is the payload and stays a bare list. The instruction that
        # drives the clear-violations loop pipes it and indexes the result, and
        # TKT-354 is already open about tira.next answering with a dict when
        # work waits and a list when it does not - the same fault from the other
        # side. Everything below is the human summary the CLI contract asks for.
        return $open if ( $option->{output} // '' ) eq 'json';

        my $at = $tira->police_outstanding_taken_at( store => $store );
        return [
            defined $at
            ? 'No violations outstanding, as of the pass at ' . $at
            : 'This board has never been policed, so nothing has been checked'
        ] if !@{$open};

        # His question, which the old output could not answer: "why the action
        # all log only? this outstanding command is act-on-it when the agent
        # look at this. they won't act on it but just log only." Both kinds come
        # back tone 'note', so tone cannot carry the difference and the action
        # has to be said.
        my @chased   = grep { ( $_->{action} // '' ) ne 'log-only' } @{$open};
        my @recorded = grep { ( $_->{action} // '' ) eq 'log-only' } @{$open};
        my $line = sub {
            my ($v) = @_;
            return sprintf '%s %s %s seen %d',
              $v->{id} // '', $v->{rule} // '', $v->{ref} // '(board)', $v->{seen} // 0;
        };

        # Each row its own answer rather than a cell in one. TOON renders an
        # array of plain strings as a single inline "primitive array" row -
        # every finding comma-joined behind one bracketed count, quote marks
        # and all - so a reader had to parse past that to find the first
        # thing. An array of single-key hashes is a different shape to TOON:
        # one row per element, which is the whole fix. TKT-291.
        my $row = sub { return { line => $_[0] } };
        my $header = scalar(@{$open}) . ' outstanding, as of the pass at '
          . ( $at // 'a time this board did not record' );

        # Grouped by rule instead of by chased/recorded, opt-in: --by-rule
        # answers "what does this board have declared against it" rather than
        # "what should I do next" - a different question, not a strictly
        # better one, so the default stays the work list. Still-act-on rules
        # sort before log-only ones, so a reader scanning groups meets the
        # same order the default view already gives findings in. Each ref
        # appears once per rule even if two policies for the same rule both
        # matched it - a display duplicate would be one thing on the board
        # read as two.
        if ( $option->{by_rule} ) {
            my %by_rule;
            my %seen;
            for my $v ( @{$open} ) {
                my $rule = $v->{rule} // '';
                next if $seen{$rule}{ $v->{ref} // '' }++;
                push @{ $by_rule{$rule} }, $v;
            }
            my @groups;
            for my $rule (
                ( sort grep { ( $by_rule{$_}[0]{action} // '' ) ne 'log-only' } keys %by_rule ),
                ( sort grep { ( $by_rule{$_}[0]{action} // '' ) eq 'log-only' } keys %by_rule ),
            ) {
                my @findings = @{ $by_rule{$rule} };
                push @groups, $row->( "$rule (" . scalar(@findings) . '):' );
                push @groups, map { $row->( '  ' . $line->($_) ) } @findings;
            }
            return [ $row->($header), @groups ];
        }

        return [
            $row->($header),
            ( @chased
                ? ( $row->( scalar(@chased) . ' to act on:' ),
                    ( map { $row->( '  ' . $line->($_) ) } @chased ) )
                : () ),
            ( @recorded
                ? ( $row->( scalar(@recorded)
                      . ' only recorded, because the board declared them log-only:' ),
                    ( map { $row->( '  ' . $line->($_) ) } @recorded ) )
                : () ),
        ];
    }

    if (   $command eq 'police.suspend'
        || $command eq 'police.log'
        || $command eq 'policy.bridge.logs' )
    {
        my $store = $option->{store}
          // _police_store( $tira->discover_project(%args) );
        return $tira->enforcement_log( %args, store => $store )
          if $command eq 'police.log' || $command eq 'policy.bridge.logs';
        my $quiet = $tira->police_suspend(
            %args, store => $store,
            seconds => $option->{seconds}, reason => $option->{reason} );

        # The owner sees every suspension as it happens, so quiet is never
        # something that simply occurs.
        print {*STDERR} "$quiet->{terminal}\n";
        return $quiet;
    }

    if ( $command eq 'police' || $command eq 'policy.bridge' ) {
        my $store = $option->{store}
          // _police_store( $tira->discover_project(%args) );

        if ( $command eq 'policy.bridge' ) {

            # Line by line, whatever this is attached to. Perl block-buffers
            # standard output when it is not a terminal, so redirected to a file
            # - the natural way to leave something running - the bridge wrote
            # nothing for sixty-eight measured minutes while violations
            # escalated to critical. The agent's only channel for violations was
            # silent, and a channel silent because it is buffered looks exactly
            # like a board that is clean.
            #
            # Localised rather than set through the handle. STDOUT->autoflush
            # was tried first and took the stream away from every later caller
            # in the process - four test files went quiet at once - which is the
            # same fault _running_quietly made by reopening it. Nothing here
            # belongs to this command after it returns.
            local $| = 1;

            # Who is tailing it. One agent per ticket means an agent's concern
            # is its own cards, so the bridge narrows to whoever says who they
            # are - by --author, or by TIRA_AUTHOR in the environment, said
            # once rather than on every command. Nobody named hears everything,
            # which is how the owner watches the whole board.
            my $agent = $option->{author};
            my $backlog = $tira->bridge_backlog( store => $store, lines => 200, agent => $agent );

            # Through _utf8_bytes like every other output path. Standard output
            # is deliberately :raw - Perl's text layer on Windows rewrites
            # newlines and Tira compares output bytes in its own cache - so a
            # print of decoded characters warns above U+00FF and, worse, writes
            # a single latin-1 byte between U+0080 and U+00FF without warning.
            # A card title carrying a multiplication sign put exactly the byte
            # tira.doctor repairs into the channel that reports it.
            print _utf8_bytes( join '', map { "$_\n" } @{$backlog} );
            _bridge_follow( $tira, $store, rounds => $option->{rounds}, agent => $agent,
                interval => $option->{interval}, sleeper => $option->{sleeper} )
              if !$option->{once};
            return { streamed => scalar @{$backlog} };
        }

        # Before anything is reported: what to hand the agent. Police watching a
        # board nobody has set up finds nothing, and that silence looks exactly
        # like compliance - so the owner gets something to copy across rather
        # than writing the instructions himself every time. Printed on every
        # run, because remembering which run was the first is the sort of thing
        # he should not have to do.
        #
        # That was a promise this comment made and the engine did not keep. A
        # board with every rule declared got undef and printed nothing, so it
        # looked exactly like a police that had died - and the boards it
        # happened to were the ones set up most carefully. Every state answers
        # now, so this line is true as written.
        my $prompt = eval { $tira->police_prompt(%args) };
        print {*STDERR} "\n$prompt\n" if defined $prompt;

        # Discovered once and handed to both. The bridge line carries the way
        # down to its card, and that path used to be looked up from the working
        # directory because this call did not say which board it was about - so
        # a violation on one board was reported with a hierarchy from whichever
        # Tira project the process happened to be standing in.
        my $watching = $tira->discover_project(%args);
        my $result = $tira->police_pass( %args, store => $store,
            world => _police_world( tira => $tira, project => $watching ) );
        die "$result->{advice}\n" if !$result->{watching};
        $tira->bridge_write( store => $store, project => $watching,
            violations => $result->{violations}, settled => $result->{settled},
            upgraded => $result->{upgraded} );
        print {*STDERR} map { "$_\n" } @{ $result->{terminal} };
        return $result if $option->{once};
        return _police_follow( $tira, \%args, $store, $option );
    }

    return _report_to_tira( $tira, \%args, $option )
      if $command eq 'dev.found.bug_or_improvement';

    return _backup( $tira, \%args ) if $command eq 'backup';
    return _backup_restore( $tira, \%args, $option ) if $command eq 'backup.restore';
    return _backup_export( $tira, \%args, $option ) if $command eq 'backup.export';
    return _backup_import( $tira, \%args, $option ) if $command eq 'backup.import';

    return $tira->policy_decline(%args) if $command eq 'policy.decline';
    return $tira->policy_declined(%args) if $command eq 'policy.declined';

    # A parallel system to ticket/epic/sow, deliberately lighter - no gates,
    # checklists, or required-actions. TKT-504.
    return $tira->tasklist_list(%args) if $command eq 'tasklist.list';
    return $tira->tasklist_sessions(%args) if $command eq 'tasklist.sessions';
    return $tira->tasklist_add( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.add';
    return $tira->tasklist_update(%args) if $command eq 'tasklist.update';

    # TKT-507: array-list operations on the tasklist queue.
    return $tira->tasklist_next( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.next';
    return $tira->tasklist_shift(%args) if $command eq 'tasklist.shift';
    return $tira->tasklist_pop(%args) if $command eq 'tasklist.pop';
    return $tira->tasklist_unshift( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.unshift';
    return $tira->tasklist_slice( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.slice';
    return $tira->tasklist_remove(%args) if $command eq 'tasklist.remove';
    return $tira->tasklist_import(%args) if $command eq 'tasklist.import';

    # TKT-508: prune, per-item attach/ref sub-verbs.
    return $tira->tasklist_prune(%args) if $command eq 'tasklist.prune';
    return $tira->tasklist_task_attach_add( %args, files => $option->{files} // [] )
      if $command eq 'tasklist.task.attach.add';
    return $tira->tasklist_task_attach_discard( %args, files => $option->{files} // [] )
      if $command eq 'tasklist.task.attach.discard';
    return $tira->tasklist_task_ref_link( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.task.ref.link';
    return $tira->tasklist_task_ref_unlink( %args, refs => $option->{ref_list} // [] )
      if $command eq 'tasklist.task.ref.unlink';

    # What the agent has not decided about. It is the only party that can
    # declare a policy, and police prints this for the owner rather than for it.
    return $tira->policy_undeclared(%args) if $command eq 'policy.undeclared';

    # The whole set in one place, for the review he does behind the agent.
    return $tira->policy_review(%args) if $command eq 'policy.review';

    if ( $command =~ /\Apolicy\.(add|list|remove)\z/ ) {
        my $action = $1;
        return $tira->policy_list(%args) if $action eq 'list';
        return $tira->policy_remove(%args) if $action eq 'remove';
        my %policy = map { $_ => $option->{$_} }
          grep { defined $option->{$_} }
          qw(rule action enter column age read_age max pattern message require require_link link_to sandbox notify);

        # Where the policy is declared decides how narrow it is: naming a
        # board, a column or a card each makes it beat the level above.
        $policy{type} = $option->{type} if defined $option->{type};
        $policy{on_column} = $option->{on_column} if defined $option->{on_column};
        $policy{ref} = $args{ref} if defined $args{ref};
        # The three role fields are not copied here. They arrive in %args
        # like every other option and policy_add reads them from there, which
        # was proved by taking the copy away and watching nothing change - so
        # the line existed to look careful rather than to do anything. TKT-221.

        # --before already means a date filter elsewhere, so the column form
        # is spelled out rather than overloading a flag that means something
        # different on every other command.
        $policy{before} = $option->{before_column} if defined $option->{before_column};
        return $tira->policy_add( %args, %policy );
    }

    if ( $command =~ /\Alogin\.(register|check|status|logout)\z/ ) {
        my $action = $1;
        return $tira->login_register( %args, password => $option->{password} )
          if $action eq 'register';

        # A wrong password and a person who does not exist must look the same
        # from outside, or the command becomes a way to find out who is here.
        return { ok => $tira->login_verify( %args, password => $option->{password} )
              ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false }
          if $action eq 'check';

        # The listing says who, never what they are holding: a token is the
        # credential itself.
        return [ map { { person => $_->{person}, started_at => $_->{started_at},
                         last_seen_at => $_->{last_seen_at} } }
                 @{ $tira->session_list(%args) } ]
          if $action eq 'status';

        die "Use --id PERSON or --all to say whose sessions to end\n"
          if !$option->{all} && ( !defined $args{id} || $args{id} eq '' );
        my $ended = 0;
        for my $session ( @{ $tira->session_list(%args) } ) {
            next if !$option->{all} && $session->{person} ne $args{id};
            $tira->session_end( %args, token => $session->{token} );
            $ended++;
        }
        return { ended => $ended };
    }

    my %method = (
        'hierarchy.link' => 'hierarchy_link', 'hierarchy.unlink' => 'hierarchy_unlink', 'hierarchy.show' => 'hierarchy_show',
        'subitem.link' => 'subitem_link', 'subitem.unlink' => 'subitem_unlink',
        'link.add' => 'link_add', 'link.remove' => 'link_remove', 'link.list' => 'link_list',
        'assign.list' => 'assignment_list', 'assign.add' => 'assignment_add',
        'assign.remove' => 'assignment_remove', 'assign.set' => 'assignment_set',
        'comment.list' => 'comment_list', 'comment.add' => 'comment_add',
        'comment.update' => 'comment_update', 'comment.remove' => 'comment_remove',
        'comment.attach' => 'comment_attach',
        'attachment.add' => 'attachment_add', 'attachment.list' => 'attachment_list',
        'attachment.get' => 'attachment_get', 'attachment.remove' => 'attachment_remove',
        'attachment.detach' => 'attachment_detach',
        'attachment.discard' => 'attachment_discard',
        'evidence.list' => 'evidence_list', 'evidence.add' => 'evidence_add',
        'evidence.annotate' => 'evidence_annotate',
        'gate.list' => 'gate_list', 'gate.add' => 'gate_add',
        'gate.annotate' => 'gate_annotate',
        'release.record' => 'release_record',
        'checklist.list' => 'checklist_list', 'checklist.add' => 'checklist_add',
        'checklist.update' => 'checklist_update',
        'required-action.list' => 'required_item_list', 'required-action.add' => 'required_item_add',
        'required-action.update' => 'required_item_update',
        'search' => 'search', 'search.index' => 'search_index', 'dashboard' => 'dashboard',
        'dashboard.sow' => 'dashboard', 'dashboard.epic' => 'dashboard', 'dashboard.ticket' => 'dashboard',
    );
    my $method = $method{$command} or die "Unsupported Tira command '$command'\n";

    # An option this command will not act on is refused rather than discarded.
    # The parser is shared, so every command sees every option, and the wrong
    # name looks accepted instead of unknown - assign.set took --assignee, threw
    # it away, printed the whole unchanged card and exited zero. A card sat in
    # implement for an hour with nobody on it because of that.
    #
    # Narrow on purpose. There is no per-command list of the options each one
    # uses, and inventing one for every command would refuse things that work
    # today. What is declared is the set where one option names the job another
    # option does, which is the set that misleads.
    for my $misleading ( @{ $MISLEADING_OPTIONS{$command} // [] } ) {
        my ( $given, $meant ) = @{$misleading};
        next if !defined $option->{$given} || $option->{$given} eq '';
        ( my $flag = $given ) =~ tr/_/-/;
        ( my $instead = $meant ) =~ tr/_/-/;
        die "$command does not act on --$flag. Use --$instead, which is what it reads.\n";
    }
    $args{person} = $option->{people}[0] if $command =~ /\Aassign\.(?:add|remove)\z/ && $option->{people};
    $args{people} = $option->{people} // [] if $command eq 'assign.set';
    $args{recursive} = $option->{recursive} if $command eq 'hierarchy.show';
    if ( $command eq 'hierarchy.link' ) {
        $args{priority} = $option->{priority} if defined $option->{priority};
        $args{assignee} = $option->{assignee} if defined $option->{assignee};
    }
    if ( $command =~ /\Adashboard(?:\.(sow|epic|ticket))?\z/ ) {
        $args{type} = $1 if defined $1;
        # Every board is created with Backlog and Discard, and the
        # owner saw one and never the other. A person looking at a board should
        # see where discarded work went; the ref-only path an agent queries is
        # untouched, so nobody pays for cards they did not ask about.
        $args{include_discard} = $option->{include_discard}
          // ( $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/ );
        $args{summary} = $option->{output} ne 'json';
        $args{with_title} = defined $option->{title};

        # A board somebody is looking at must show which cards are waiting,
        # whether or not they asked for titles. The ref-only path an agent
        # queries stays untouched.
        $args{with_questions} = $option->{with_questions}
          // ( $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/ );
        $args{include_mtime} = $option->{include_mtime} || $option->{output} eq 'table' || $option->{output} =~ /\Abrowser(?:=|\z)/;
    }
    $args{include_deleted} = $option->{include_deleted} if $command eq 'attachment.list';
    $args{questions} = $option->{questions} if $command eq 'attachment.list' && $option->{questions};
    if ( $command =~ /\Acomment\.(?:add|update)\z/ && defined $option->{file} ) {
        die "Use only one of --text or --file\n" if defined $option->{text};
        $args{text} = _text_input( $option->{file}, utf8 => 1 );
    }
    # Several files, one invocation. The cost this fixes is per command
    # RESOLUTION, not per attachment: measured on 2.64, an unknown tira command
    # costs 0.50s while the attachment work itself is about 0.05s, and a 400-card
    # board is no slower than a 1-card one. Six files in a shell loop was 3.87s,
    # of which roughly 3.0s was finding the command six times.
    #
    # So looping HERE is the whole fix and looping in a shell is what was slow -
    # which is why t/275 asserts this is one invocation rather than only that the
    # files arrived. Same shape as comment.add --attach below, which has batched
    # all along and which nothing documented as a batch. TKT-338.
    #
    # A file part-way through that cannot be read still dies - a bad path is
    # still a mistake worth stopping for - but the files attached before it are
    # returned rather than lost with the die, because his second ask was exactly
    # this: a killed batch should leave a readable record of how far it got,
    # not force reading the card back to find out what landed. Caught by testing
    # the failure path this card exists because of, rather than only the happy
    # one: the first version of this loop reported nothing at all on a partial
    # failure, reproducing in a new shape the blindness it was written to fix.
    if ( $command eq 'attachment.add' && $option->{files} && @{ $option->{files} } > 1 ) {
        my @added;
        for my $path ( @{ $option->{files} } ) {
            my $one = eval { $tira->attachment_add( %args, file => $path ) };
            if ( !$one ) {
                die "$@" . ( @added ? "\nAttached before the failure: "
                    . join( ', ', map { $_->{original_filename} } @added ) . "\n" : '' );
            }
            push @added, $one;
        }
        return \@added;
    }

    if ( $command eq 'comment.add' && $option->{attach} ) {
        my $comment = $tira->$method(%args);
        $tira->comment_attach( %args, comment => $comment->{id}, file => $_ ) for @{ $option->{attach} };
        return $tira->comment_list(%args)->[-1];
    }
    return $tira->$method(%args);
}

# Police keeps its state outside the project it watches, so that it can never
# become a second writer to the board - which is what destroyed this project's
# own board on the day the subsystem was designed.
# One directory per board, named for it, so two boards never write over each
# other - the rule _backup_home states forty lines below and this did not keep.
#
# It took the --project OPTION and called the answer 'here' when there was none.
# Police started from inside a project passes no --project, so every board
# worked that way shared a single store: the version each board last heard, the
# violation numbering, the escalation counts, the suspensions, and the bridge
# log they are written to. A board was never told about an upgrade because a
# different board had already been told about it.
#
# Refused rather than invented now. Every caller has a board to hand - police
# discovers one before it can watch anything - so there is no case where a name
# has to be made up, and inventing one is what made the sharing silent.
sub _police_store {
    my ($project) = @_;
    die "A police store has to belong to a board, and none was given\n"
      if !defined $project || $project !~ /\S/;
    my $home = $ENV{HOME} // File::Spec->tmpdir;
    my $slug = $project;
    $slug =~ s/[^A-Za-z0-9]+/-/g;
    $slug =~ s/\A-|-\z//g;
    return File::Spec->catdir( $home, '.tira-police', $slug );
}

# The world police needs and the engine will not touch. Gathered here, handed
# in as plain facts, so that Tira itself still invokes no shell.
#
# It used to return five empty lists and nothing else. Six declared rules read
# this - leftover-process, leftover-container, commit-without-card,
# work-without-card, unpushed-work and board-unbacked - and every one of them
# evaluated against nothing and stayed silent. A rule that is silent because it
# was shown nothing looks exactly like a rule being obeyed, which is the very
# sentence police prints to the owner when a rule is missing entirely. Found on
# 2026-08-12, when board-unbacked said the board had never been backed up while
# the backups the push gate writes sat in ~/.tira-backups.
sub _police_world {
    my (%args) = @_;
    my $root = $args{project};

    # The repository the project declared, when it declared one. Police used to
    # run git in the directory holding the board, which is the right guess only
    # when the two are the same place - and on a board that sits outside its
    # repository every question came back empty, so card-sandbox-missing
    # reported every card as missing a branch and a work tree that both existed.
    #
    # Declared beats guessed and nothing else changes: a board that does sit
    # inside its repository still finds it without saying anything.
    my $declared = eval {
        Tira->new->project_show( project => $root )->{repo};
    };
    my $where =
        ( defined $declared && $declared ne '' && -d $declared ) ? $declared
      : ( defined $root && -d $root ) ? $root
      :                                 undef;

    my $world = {
        branches   => _git_branches($where),
        worktrees  => _git_worktrees($where),
        processes  => _running_processes(),
        containers => _running_containers(),
        commits    => _unpushed_commits($where),
    };
    $world->{unpushed_since} = @{ $world->{commits} } ? $world->{commits}[-1]{at} : undef;
    $world->{working_since} = _tree_changing_since($where);
    # The board's own repository first, because that is what tira.backup writes
    # and what any board can have. The old answer was a directory of stamps
    # under the home directory that only one repository on earth wrote to, so
    # every other board was told it had never been backed up and had no way to
    # change that. It is still read, so a board backed up by the old tool is not
    # suddenly told it never was.
    #
    # Asked about the board, not about $where. Every other question here is
    # about the repository the work happens in; this one is about the board,
    # and tira.backup, tira.backup.restore and tira.backup.export all resolve
    # the store from the board root. Asking it with $where meant that a project
    # which declared a repository had its backups looked for inside the code -
    # where there are none - and board-unbacked told it that it had never been
    # backed up, permanently, whatever anybody did.
    #
    # developer-dashboard reported exactly that on 2026-08-15: the rule raised
    # at 07:55 and escalated twice while the board was backed up three times in
    # between, against a seven-day age. One variable was answering two
    # questions, which are the same place until somebody says otherwise.
    #
    # And both mechanisms, not the first one that answers. `//` meant "the
    # commit, or the directories if there is no commit", when the question is
    # when this board was last backed up by anything at all. tools/board-backup
    # writes the directories on every push and tira.backup writes the commit, so
    # a board the gate had backed up 481 times was told its last backup was the
    # one somebody ran by hand six hours earlier - and advised to run that same
    # command. The later of the two is the answer.
    $world->{backed_up_at} = _later_backup(
        _last_backup_commit( _backup_store($root) ),
        _last_backup( $args{backups} // _backup_home($root) ),
    );
    $world->{card_in_progress} = exists $args{card_in_progress}
      ? $args{card_in_progress}
      : _card_in_progress( $args{tira}, $root );
    return $world;
}

# Whether anything on the board is being worked. work-without-card asks it the
# other way round - a tree that is changing while nothing is at a working gate
# is work nobody can see - so getting this wrong makes that rule accuse the
# agent of exactly what it is in the middle of doing properly.
sub _card_in_progress {
    my ( $tira, $root ) = @_;
    return undef if !$tira || !defined $root;
    # Where work happens, asked of the board rather than read off one role.
    #
    # This counted a card as being worked only if it sat in the single column
    # named by the in-progress role, when a board declared one. On this project's
    # own board - in-progress=implement, five columns work happens in - that left
    # tests-red, verify, document and push reading as nobody working, and
    # work-without-card raised VIO-0013 to CRITICAL five times while a card sat
    # in verify with its suite running.
    #
    # A setting that names one column stops covering the board the moment work
    # happens in another, which is the fault column-unwatched reports for
    # policies. The role was accurate when it was set; the board grew.
    #
    # The same question card-unassigned and priority-skipped ask: not protected,
    # and not an ending. A board that has marked nothing terminal ends in `done`,
    # which is the fallback those rules use too. The in-progress role is still a
    # role like any other - a policy can name it with --enter-role - it simply no
    # longer narrows this silently.
    my $working = 0;
    for my $type (qw(sow epic ticket)) {
        my $columns = eval { $tira->column_list( project => $root, type => $type ) } || [];
        my $records = eval { $tira->record_list( project => $root, type => $type ) } || [];
        my %ends = map { $_->{name} => 1 } grep { $_->{terminal} } @{$columns};
        $ends{done} = 1 if !keys %ends;
        my %here = map { $_->{name} => 1 }
          grep { !$_->{protected} && !$ends{ $_->{name} } } @{$columns};

        for my $record ( @{$records} ) {
            $working++, last if $here{ $record->{column} // '' };
        }
        last if $working;
    }
    return $working ? 1 : 0;
}

# Every external command runs through here, in list form so no shell is
# involved even in this module - a card title with a semicolon in it is a
# perfectly ordinary card title. A command that is not installed is not a
# failure: a machine with no Docker has no leftover containers.
sub _reading {
    my (@command) = @_;

    # List form: the program is named separately from its arguments, so this is
    # always "run this program" and never "ask a shell what was meant" - a card
    # title with a semicolon in it is an ordinary card title. A program that is
    # not installed is not a failure either: a machine with no Docker has no
    # leftover containers, and everything else carries on being watched.
    # Asked for by name first. Perl warns "Can't exec" when a program is not
    # there, and a machine with no Docker is not an error worth printing into
    # the middle of whatever the owner was reading.
    return [] if !_program_exists( $command[0] );

    my @lines;
    if ( open my $handle, '-|', @command ) {
        @lines = <$handle>;
        close $handle;
    }
    chomp @lines;
    return \@lines;
}

# Running a program for its effect rather than its words. _reading throws the
# exit status away, which is right for reading the machine - a box with no
# Docker has no containers - and wrong for a backup, where "it did not work" is
# the only answer that matters.
# An identity given on the command rather than written into the repository. A
# backup must not depend on whoever runs it having configured git, and must not
# quietly change what their own git would do.
my @BACKUP_AUTHOR = (
    '-c', 'user.name=Tira', '-c', 'user.email=tira@localhost',
    '-c', 'commit.gpgsign=false',
);

# A backup is a commit. His design, and the right one: the board is a directory
# of files, git is what keeps a directory of files, and a repository with no
# remote cannot fail because somebody else's machine is down.
#
# Nothing exists until the first backup, so a board that leaves the policy out
# is untouched on disk - and nobody has to run git init to obey a rule, because
# a command that works only after an invisible setup step is one that leaves the
# rule firing anyway.
sub _backup {
    my ( $tira, $args ) = @_;
    my $root = $tira->discover_project( %{$args} );
    my $store = _backup_store($root);

    die "Tira needs git to back a board up, and it is not installed here\n"
      if !_program_exists('git');

    my $created = -d File::Spec->catdir( $store, '.git' ) ? 0 : 1;
    if ($created) {
        _running( 'git', '-C', $store, 'init', '--quiet' )
          or die "Could not start a repository for this board at $store\n";
    }

    # What a backup leaves out, checked on every run rather than at creation.
    #
    # The lock is about right now rather than about the board, and a restored
    # lock is a wedged board. A session is the server side of somebody's
    # sign-in: a restored one hands over an identity, which is worse than a
    # stale lock stopping one write. Neither is state worth having back.
    #
    # Written every time because it used to be written only when the store was
    # created, so a board made before a line was added here would never see it -
    # and every board that exists today was made before this one.
    #
    # Sessions are also rewritten whenever anybody uses the board, so while they
    # were tracked there was always something pending and tira.backup reported
    # changed: 1 on runs seconds apart with nothing touched. That is what he
    # noticed, and why "is this board already backed up" had no answer.
    {
        my $ignore = File::Spec->catfile( $store, '.gitignore' );
        my %already;
        if ( open my $read, '<', $ignore ) {
            while ( my $line = <$read> ) { chomp $line; $already{$line} = 1 }
            close $read;
        }
        my @missing = grep { !$already{$_} } ( '.lock', 'sessions/' );
        if (@missing) {
            open my $handle, '>>', $ignore or die "Could not write $ignore: $!\n";
            print {$handle} "$_\n" for @missing;
            close $handle;

            # Ignoring a path git is already tracking changes nothing, so a
            # board that has been backed up before has to be told to stop
            # carrying them. Only the index: what the history already holds
            # stays there, because rewriting the history of a backup is a worse
            # thing to own than the tidiness it buys.
            # _running, not _running_quietly. git's own --quiet and
            # --ignore-unmatch already keep it silent, and _running_quietly was
            # measured to silence everything this process prints afterwards when
            # standard output is an in-memory handle - which is how every test
            # in this suite captures output. Raised separately; not worked
            # around here, because the plain call is also the simpler one.
            _running( 'git', '-C', $store, 'rm', '-r', '--cached', '--quiet',
                '--ignore-unmatch', 'sessions' );
        }
    }

    _running( 'git', '-C', $store, 'add', '--all' )
      or die "Could not read the board into the backup\n";

    my $pending = _reading( 'git', '-C', $store, 'status', '--porcelain' );
    my $changed = @{$pending} ? 1 : 0;

    if ($changed) {
        my $count = scalar @{$pending};
        my $message = $created
          ? 'The board as it stands, backed up for the first time'
          : "$count " . ( $count == 1 ? 'thing' : 'things' ) . ' changed since the last backup';
        _running( 'git', '-C', $store, @BACKUP_AUTHOR, 'commit', '--quiet', '-m', $message )
          or die "Could not record the backup\n";
    }

    my ($commit) = @{ _reading( 'git', '-C', $store, 'rev-parse', '--short', 'HEAD' ) };
    return {
        commit  => $commit,
        at      => _last_backup_commit($store),
        created => $created,
        changed => $changed,
        store   => $store,
        message => $changed
          ? 'The board is backed up.'
          : 'Nothing has changed since the last backup, so it still stands.',
    };
}

# Putting a board back. His design: git reset --hard, so a restore is a restore
# and anything done since the backup is gone.
#
# Which is exactly why it says what it is about to discard first and does
# nothing until that is agreed to. This is the only command in Tira that can
# lose work, and a command that destroys in silence is one people either stop
# running or run without reading.
sub _backup_restore {
    my ( $tira, $args, $option ) = @_;
    my $root = $tira->discover_project( %{$args} );
    my $store = _backup_store($root);

    die "Tira needs git to restore a board, and it is not installed here\n"
      if !_program_exists('git');
    die "This board has never been backed up, so there is nothing to restore it to.\n"
      . "Make one first: d2 tira.backup\n"
      if !defined _last_backup_commit($store);

    # What would be lost, read before anything is touched. Named rather than
    # counted: "3 files would be discarded" tells nobody whether it matters.
    my $changed = _reading( 'git', '-C', $store, 'status', '--porcelain' );
    my @losing = map { s/\A.{3}//r } @{$changed};

    if ( !$option->{yes} ) {

        # Printed rather than thrown, because a refusal is only useful if it can
        # be read. A structured error carries one string, and a multi-line
        # warning inside one arrives as literal backslash-n on the terminal -
        # which is how the one command that can destroy a board ends up with a
        # warning nobody reads.
        print {*STDERR} "Restoring puts this board back to its last backup and discards\n"
          . "what has happened since. That is:\n\n";
        print {*STDERR} @losing
          ? join( '', map { "  $_\n" } @losing )
          : "  nothing - the board is exactly as it was backed up\n";
        print {*STDERR} "\nRun it again with --yes if that is what you want.\n\n";
        die "Nothing was restored, because --yes was not given\n";
    }

    _running( 'git', '-C', $store, 'reset', '--hard', 'HEAD' )
      or die "Could not put the board back\n";

    # A file added since the backup is untracked, so reset leaves it exactly
    # where it was - and a card raised since would survive a restore that
    # reported success. Cleaning is the half of "put it back" that reset alone
    # does not do.
    _running( 'git', '-C', $store, 'clean', '--force', '-d', '--quiet' )
      or die "Could not clear what was added since the backup\n";

    my ($commit) = @{ _reading( 'git', '-C', $store, 'rev-parse', '--short', 'HEAD' ) };
    return {
        commit    => $commit,
        at        => _last_backup_commit($store),
        discarded => \@losing,
        store     => $store,
        message   => 'The board is back as it was when it was last backed up.',
    };
}

# The schema this Tira understands. A board written by a newer one may hold
# shapes these readers have never seen, and no amount of care here can invent
# them - so it is refused rather than half-restored. The other direction needs
# nothing: an older board already works, because this codebase applies defaults
# on read instead of migrating.
our $SCHEMA_VERSION = 2;

# Getting a backup off the machine. The repository lives inside the board's own
# storage, so it survives a bad edit and not a lost disk - and a bundle is one
# file holding the whole history, kept wherever the owner keeps things.
sub _backup_export {
    my ( $tira, $args, $option ) = @_;
    my $root  = $tira->discover_project( %{$args} );
    my $store = _backup_store($root);
    my $file  = $option->{file}
      or die "Where should the bundle go? Name it: --file board.bundle\n";

    die "Tira needs git to export a backup, and it is not installed here\n"
      if !_program_exists('git');
    die "This board has never been backed up, so there is nothing to export.\n"
      . "Make a backup first: d2 tira.backup\n"
      if !defined _last_backup_commit($store);

    _running( 'git', '-C', $store, 'bundle', 'create', $file, '--all' )
      or die "Could not write the bundle to $file\n";

    return {
        file    => $file,
        at      => _last_backup_commit($store),
        message => "The board is in $file. Keep it somewhere the board is not.",
    };
}

# And bringing one back. The folder becomes what the bundle holds - his words:
# git reset --hard - so this can lose work exactly as a restore can, and says
# what it would discard before it does anything.
sub _backup_import {
    my ( $tira, $args, $option ) = @_;
    my $file = $option->{file}
      or die "Which bundle? Name it: --file board.bundle\n";
    die "There is no bundle at $file\n" if !-f $file;

    die "Tira needs git to import a backup, and it is not installed here\n"
      if !_program_exists('git');
    # Verified in a repository of its own, because git will not read a bundle
    # from outside one - and the destination must not be touched until the
    # bundle is known to be good, or a refusal leaves a half-made board behind.
    require File::Temp;
    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    _running( 'git', '-C', $scratch, 'init', '--quiet' )
      or die "Could not check the bundle: no scratch repository\n";
    _running_quietly( 'git', '-C', $scratch, 'bundle', 'verify', $file )
      or die "$file is not a bundle git can read\n";

    # Claimed rather than read out of the bundle, because reading it means
    # unpacking it first - and unpacking a bundle from a newer Tira is the thing
    # being refused. The claim is what an exporter of a later release would
    # write beside it.
    my $claimed = $option->{claiming_schema};
    die "That bundle was made by a newer Tira (schema $claimed, this one reads "
      . "$SCHEMA_VERSION). Upgrade Tira and import it again.\n"
      if defined $claimed && $claimed > $SCHEMA_VERSION;

    # Where it is going, named as a folder rather than selected as a board.
    # discover_project would walk upwards and find somebody else's, so the
    # folder is taken as given: importing is how a board comes into existence
    # somewhere, not something done to one that is found. That is why this
    # takes --dir, like creating a board does, while everything that works on
    # an existing board is told which one in the environment. TKT-250.
    my $where = $option->{dir} // $args->{project}
      or die "Where should the board go? Name the folder it should be made in.\n";
    my $store = _backup_store($where);

    my $existing = -d File::Spec->catdir( $store, '.git' ) ? 1 : 0;
    if ( $existing && !$option->{yes} ) {
        my @losing = map { s/\A.{3}//r }
          @{ _reading( 'git', '-C', $store, 'status', '--porcelain' ) };
        print {*STDERR} "There is already a board here, and importing replaces it\n"
          . "with what the bundle holds. Uncommitted work here:\n\n";
        print {*STDERR} @losing
          ? join( '', map { "  $_\n" } @losing )
          : "  none, but every card in this board would be replaced\n";
        print {*STDERR} "\nRun it again with --yes if that is what you want.\n\n";
        die "Nothing was imported, because --yes was not given\n";
    }

    File::Path::make_path($store) if !-d $store;
    if ( !$existing ) {
        _running( 'git', '-C', $store, 'init', '--quiet' )
          or die "Could not start a repository at $store\n";
    }
    _running( 'git', '-C', $store, 'fetch', '--quiet', $file, 'HEAD' )
      or die "Could not read the bundle into the board\n";
    _running( 'git', '-C', $store, 'reset', '--hard', 'FETCH_HEAD' )
      or die "Could not lay the board out from the bundle\n";
    _running( 'git', '-C', $store, 'clean', '--force', '-d', '--quiet' )
      or die "Could not clear what was here before the import\n";

    my ($commit) = @{ _reading( 'git', '-C', $store, 'rev-parse', '--short', 'HEAD' ) };
    return {
        commit  => $commit,
        at      => _last_backup_commit($store),
        store   => $store,
        message => 'The board is here, as it was when that bundle was made.',
    };
}

# Running something whose own chatter is not the caller's business. git bundle
# verify prints "<file> is okay" on the error stream when it succeeds, and a
# successful import that prints to stderr reads like a warning to anybody
# watching. Its answer is the exit status; its opinion is noise.
# Running something whose own chatter is not the caller's business. git prints
# "<file> is okay" on the error stream when a bundle verifies, and a successful
# command that writes to stderr reads like a warning to whoever is watching.
#
# The parent hands the child a filehandle for its error stream, so nothing in
# this process is reopened and no Perl runs in the child. Two other ways were
# tried and both cost more than the line is worth: reopening this process's
# stream took it away from every caller that had redirected it, and forking a
# child that silences itself puts lines in the codebase that no coverage tool
# can measure, because the child execs away before any counter is written.
# Move the descriptors, not the globs.
#
# open3 silences a child by reopening the STDOUT and STDERR globs after it
# forks, which moves descriptors 1 and 2 only while those globs still own them.
# A caller that captured its own output into a string - every test in this
# suite, and the served dashboard collecting a response - leaves the glob with
# no descriptor at all, so nothing the child does to it reaches descriptor 1,
# exec passes the real one through, and the command that was run quietly is
# heard. Measured rather than reasoned: the pipe open3 set up received nothing
# and the process's own standard output received "git version 2.52.0".
#
# No choice of open3 argument fixes that - a handle, a fileno dup string and a
# second null device were each tried and each leaked identically - because the
# fault is on the parent's side of the fork. Pointing the descriptors themselves
# at the null device first means the child inherits harmless ones whatever the
# globs are doing.
#
# The same hole sits on the error stream. t/139 does not reach it because it
# reopens STDERR onto a real file, which hands descriptor 2 back a real
# descriptor and hides the fault - the same way an earlier attempt at t/204
# went green by aiming descriptor 1 at a file.
#
# Both are put back before returning, so a caller keeps the output it had; that
# is the failure t/139 records, and it is asserted here rather than assumed.
sub _running_quietly {
    my (@command) = @_;
    return 0 if !_program_exists( $command[0] );
    require POSIX;
    open my $silence, '>', File::Spec->devnull
      or die "Cannot open the null device to run $command[0] quietly: $!\n";
    open my $nothing, '<', File::Spec->devnull
      or die "Cannot open the null device to run $command[0] quietly: $!\n";

    # Remembered as descriptors for the same reason: a glob that has been
    # captured cannot be duplicated back afterwards.
    open my $keep_in,  '<&', 0 or die "Cannot remember standard input: $!\n";
    open my $keep_out, '>&', 1 or die "Cannot remember standard output: $!\n";
    open my $keep_err, '>&', 2 or die "Cannot remember the error stream: $!\n";

    POSIX::dup2( fileno($nothing), 0 );
    POSIX::dup2( fileno($silence), 1 );
    POSIX::dup2( fileno($silence), 2 );

    # The child reads end-of-file rather than blocking on a pipe nobody writes
    # to, which is what the previous code left it holding.
    my $status = system(@command);

    POSIX::dup2( fileno($keep_in),  0 );
    POSIX::dup2( fileno($keep_out), 1 );
    POSIX::dup2( fileno($keep_err), 2 );

    return $status == 0 ? 1 : 0;
}

sub _running {
    my (@command) = @_;
    return 0 if !_program_exists( $command[0] );
    my $pid = open my $handle, '-|', @command or return 0;
    my @said = <$handle>;
    close $handle;
    return $? == 0 ? 1 : 0;
}

# The board's own storage, which is what gets backed up: everything beside
# project.yml, because that is where he said the repository goes.
sub _backup_store {
    my ($root) = @_;
    return undef if !defined $root;
    return File::Spec->catdir( $root, '.tira' );
}

# When the last backup was, read from the repository rather than from a
# directory of stamps that only one machine on earth ever wrote to. Nothing is
# created by asking: a board that has never been backed up answers undef and is
# left exactly as it was.
# Asked as an instant rather than as a local wall clock. This read %cI and
# threw the offset away, so a commit at 01:03+01:00 was recorded as 01:03Z - an
# hour later than it happened, labelled with the one timezone it was not in.
# On its own that was an hour of slack in an age measured in days. It stopped
# being harmless when this answer began to be compared with the gate's, which
# stamps its directories in real UTC: the same instant read as two times an
# hour apart, and the wrong one could win.
sub _last_backup_commit {
    my ($store) = @_;
    return undef if !defined $store || !-d File::Spec->catdir( $store, '.git' );
    my ($when) = @{ _reading( 'git', '-C', $store, 'log', '-1', '--format=%ct' ) };
    return undef if !defined $when || $when !~ /\A(\d+)\z/;
    my @moment = gmtime($1);
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $moment[5] + 1900, $moment[4] + 1, $moment[3], $moment[2], $moment[1], $moment[0];
}

sub _program_exists {
    my ($program) = @_;
    return ( $WINDOWS ? -f $program : -x $program ) ? 1 : 0 if $program =~ m{[/\\]};
    return _agent_available($program);
}

# Asking git about somewhere that is not a repository makes git say so, on
# standard error, in the middle of whatever the owner was reading. Nothing here
# silences it, because silencing the whole program's standard error would take
# it away from whoever else was using it - a test capturing it, most obviously.
# So it is not provoked in the first place.
sub _is_repository {
    my ($where) = @_;
    return 0 if !defined $where;
    my $here = abs_path($where) // $where;
    my $last = '';
    while ( $here ne $last ) {
        return 1 if -e File::Spec->catfile( $here, '.git' );
        ( $last, $here ) = ( $here, dirname($here) );
    }
    return 0;
}

# -C rather than chdir, so the whole of this module stays in one directory and
# nothing has to be put back afterwards.
sub _git_branches {
    my ($where) = @_;
    return [] if !_is_repository($where);
    return _reading( 'git', '-C', $where, 'branch', '--format=%(refname:short)' );
}

sub _git_worktrees {
    my ($where) = @_;
    return [] if !_is_repository($where);
    return [ map { s/\Aworktree\s+//r } grep { /\Aworktree\s/ }
          @{ _reading( 'git', '-C', $where, 'worktree', 'list', '--porcelain' ) } ];
}

# The process table, with when each one started, because every rule about a
# leftover asks how long it has been there rather than whether it exists.
sub _running_processes {
    return _processes_from_windows( _reading( _process_command($WINDOWS) ) ) if $WINDOWS;
    return _processes_from( _reading( _process_command($WINDOWS) ) );
}

# What to ask for the process table. ps does not exist on Windows, and asking
# for it there is asking a question that can only be answered with nothing -
# and nothing is exactly what "no leftover processes" looks like.
#
# The platform is a parameter rather than read here, so both answers can be
# checked from anywhere. A Windows claim that can only be checked on Windows is
# one that goes unchecked, which is how this shipped eleven times.
sub _process_command {
    my ($windows) = @_;
    return $windows
      ? ( 'tasklist', '/fo', 'csv', '/nh' )
      : ( 'ps', '-eo', 'pid=,lstart=,args=' );
}

# tasklist gives a quoted CSV of name, pid, session, session number and memory,
# and no start time at all. The time is left undefined rather than invented: a
# rule that asks how long something has been running can then tell that it does
# not know, where a made-up time would make every age wrong instead of absent.
sub _processes_from_windows {
    my ($lines) = @_;
    my @processes;
    for my $line ( @{$lines} ) {
        next if $line !~ /\A"([^"]*)","(\d+)"/;
        push @processes, { pid => 0 + $2, command => $1, started_at => undef };
    }
    return \@processes;
}

# Reading the table is kept apart from asking for it, so what this understands
# can be proved against real ps output on a machine where the answer is known.
sub _processes_from {
    my ($lines) = @_;
    my @processes;
    for my $line ( @{$lines} ) {

        # Day name, then two fields in whichever order this platform prints
        # them - Linux gives "Tue May 26" and macOS "Thu 13 Aug". Matching a
        # month name in a fixed position read 711 of 711 lines on Linux and 0
        # of 192 on macOS, so leftover-process reported nothing on a Mac
        # whatever was running.
        next if $line !~ /\A\s*(\d+)\s+(\w{3}\s+\w+\s+\w+\s+[\d:]+\s+\d{4})\s+(.*)\z/;
        my ( $pid, $started, $command ) = ( $1, $2, $3 );
        next if $pid == $$;
        push @processes,
          { pid => $pid, started_at => _stamp_from_ps($started), command => $command };
    }
    return \@processes;
}

# The month is whichever of the two fields is a month name, and the day is the
# other one. Deciding by platform would be wrong on the first machine whose
# locale prints something nobody anticipated; deciding by which field is a
# month needs no knowledge of where it is running at all.
sub _stamp_from_ps {
    my ($text) = @_;
    my %month = do { my $n = 0; map { $_ => ++$n } qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) };
    return undef
      if $text !~ /\A\w{3}\s+(\w+)\s+(\w+)\s+(\d+):(\d+):(\d+)\s+(\d{4})\z/;

    my ( $first, $second, $hour, $minute, $second_of, $year ) = ( $1, $2, $3, $4, $5, $6 );
    my ( $name, $day ) =
        $month{$first}  ? ( $first,  $second )
      : $month{$second} ? ( $second, $first )
      :                   ( undef,   undef );
    return undef if !defined $name || $day !~ /\A\d+\z/;

    return sprintf '%04d-%02d-%02dT%02d:%02d:%02d',
      $year, $month{$name}, $day, $hour, $minute, $second_of;
}

sub _running_containers {
    return _containers_from(
        _reading( 'docker', 'ps', '--format', '{{.Names}}\t{{.CreatedAt}}' ) );
}

# Kept apart from asking Docker for the same reason: the suite runs inside a
# container with no Docker in it, so asking would prove nothing about whether
# the answer is understood. This is proved against real docker ps output.
sub _containers_from {
    my ($lines) = @_;
    my @containers;
    for my $line ( @{$lines} ) {
        my ( $name, $created ) = split /\t/, $line, 2;
        next if !defined $name || $name eq '';
        push @containers, { name => $name, started_at => _stamp_from_docker($created) };
    }
    return \@containers;
}

sub _stamp_from_docker {
    my ($text) = @_;
    return undef if !defined $text;
    return $text =~ /(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/
      ? "$1-$2-$3T$4:$5:$6"
      : undef;
}

# Where this branch was last pushed to. Asking git for @{upstream} was the
# obvious way and the wrong one: this very repository has origin/master and one
# unpushed commit, and no upstream configured for the branch - so git answered
# "fatal: no upstream configured", loudly, on somebody else's terminal, and
# both rules that depend on this went quiet on the one board that most needed
# them. --verify --quiet asks without complaining, and the remote the branch
# names is tried when the usual one is not there.
sub _tracking_branch {
    my ( $where, $branch ) = @_;
    my ($configured) =
      @{ _reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', '--verify', '--quiet',
            "$branch\@{upstream}" ) };
    return $configured if defined $configured && $configured ne '';

    my @remotes = ('origin');
    my ($named) = @{ _reading( 'git', '-C', $where, 'config', '--get', "branch.$branch.remote" ) };
    unshift @remotes, $named if defined $named && $named ne '';
    for my $remote (@remotes) {
        my ($found) = @{ _reading( 'git', '-C', $where, 'rev-parse', '--verify', '--quiet',
                "$remote/$branch" ) };
        return "$remote/$branch" if defined $found && $found ne '';
    }
    return undef;
}

# Commits this branch has and the branch it is pushed to does not. Nowhere to
# have been pushed means nothing is sitting unpushed - a branch nobody has ever
# pushed is not the same as work left waiting.
sub _unpushed_commits {
    my ($where) = @_;
    return [] if !_is_repository($where);
    my ($branch) = @{ _reading( 'git', '-C', $where, 'rev-parse', '--abbrev-ref', 'HEAD' ) };
    return [] if !defined $branch || $branch eq '' || $branch eq 'HEAD';
    my $upstream = _tracking_branch( $where, $branch );
    return [] if !defined $upstream || $upstream eq '';
    my $lines = _reading( 'git', '-C', $where, 'log', '--format=%H%x09%cI%x09%s', "$upstream..HEAD" );
    return [ map { my ( $sha, $at, $subject ) = split /\t/, $_, 3;
            { sha => $sha, at => $at, subject => $subject // '' } } @{$lines} ];
}

# When the working tree last changed, which is what work-without-card means by
# work. A clean tree is not work in progress, so it answers with nothing.
sub _tree_changing_since {
    my ($where) = @_;
    return undef if !_is_repository($where);
    my $changed = _reading( 'git', '-C', $where, 'status', '--porcelain' );
    return undef if !@{$changed};
    my $oldest;
    for my $line ( @{$changed} ) {
        next if $line !~ /\A.{3}(.+)\z/;
        my $path = File::Spec->catfile( $where, $1 );
        next if !-e $path;
        my $when = ( stat $path )[9];
        $oldest = $when if !defined $oldest || $when < $oldest;
    }
    return undef if !defined $oldest;
    my @when = gmtime $oldest;
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $when[5] + 1900, $when[4] + 1, @when[ 3, 2, 1, 0 ];
}

# Where tools/board-backup writes: one directory per project, named for the
# absolute path so two projects on one machine never write over each other.
sub _backup_home {
    my ($where) = @_;
    return undef if !defined $where;
    my $home = $ENV{HOME} // $ENV{USERPROFILE};
    return undef if !defined $home;
    my $slug = abs_path($where) // $where;
    $slug =~ s/[^A-Za-z0-9]+/-/g;
    $slug =~ s/\A-|-\z//g;
    return File::Spec->catdir( $home, '.tira-backups', $slug );
}

# The most recent backup, read from the stamp in its name. The newest one is
# the only one the rule cares about - it asks how long it has been since the
# last one, not how many there have ever been.
# The later of two answers about the same board, either of which may be
# missing. Both are written as YYYY-MM-DDTHH:MM:SSZ, so the comparison is the
# one the strings already support.
sub _later_backup {
    my @when = grep { defined && length } @_;
    return undef if !@when;
    return ( sort @when )[-1];
}

sub _last_backup {
    my ($directory) = @_;
    return undef if !defined $directory || !-d $directory;
    opendir my $handle, $directory or return undef;
    my @stamps = sort grep { /\A\d{8}T\d{6}Z\z/ } readdir $handle;
    closedir $handle;
    return undef if !@stamps;
    return $stamps[-1] =~ /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/
      ? "$1-$2-$3T$4:$5:$6Z"
      : undef;
}

# A loop that never ends cannot be called by anything, including a test - so
# the number of rounds and the waiting are both injectable. Left alone it runs
# for ever, which is what an agent tailing a bridge wants.
sub _bridge_follow {
    my ( $tira, $store, %args ) = @_;
    my $rounds = $args{rounds};
    my $wait = $args{sleeper} || sub { sleep $_[0] if $_[0] };
    my $every = defined $args{interval} ? $args{interval} : 2;
    my $path = $tira->bridge_log_path( store => $store );

    # Counted through the same filter the agent reads through, or a line
    # written for somebody else would advance the mark and swallow the next
    # line that was actually for this one.
    my %narrow = ( store => $store, lines => 1_000_000,
        ( defined $args{agent} ? ( agent => $args{agent} ) : () ) );
    my $seen = -f $path ? scalar @{ $tira->bridge_backlog(%narrow) } : 0;
    my $done = 0;
    while ( !defined $rounds || $done < $rounds ) {
        $done++;
        $wait->($every);
        my $all = $tira->bridge_backlog(%narrow);
        next if @{$all} <= $seen;
        # Encoded here too, and not only in the replay: fixing the first screen
        # and leaving every line after it wrong is the worse half, because a
        # tail is what an agent leaves running.
        print _utf8_bytes( join '', map { "$_\n" } @{$all}[ $seen .. $#{$all} ] );
        $seen = scalar @{$all};
    }
    return $seen;
}

sub _police_follow {
    my ( $tira, $args, $store, $option ) = @_;
    my $interval = defined $option->{interval} ? $option->{interval} : 30;
    my $rounds = $option->{rounds};
    my $wait = $option->{sleeper} || sub { sleep $_[0] if $_[0] };

    # d2 tira.police is a singleton, his own words after two live daemons on
    # one board raced the enforcement ledger (TKT-486): "Whoever the last run
    # it is the winner and the loser process will be killed." Claimed once,
    # here, before the watch starts - not for --once, a single pass that is
    # not "a process" in the sense that answer means, and killing a real
    # watcher because something asked it a quick status question would be
    # more surprising than helpful. TKT-492.
    my $claim = _police_claim_singleton( $store, %{ $option->{singleton} // {} } );
    print {*STDERR} "police: killed a still-running daemon (pid $claim->{killed}) - only the newest watches now\n"
      if defined $claim->{killed};

    # A supervisor that dies quietly is worse than none, because its silence
    # reads as everything being fine.
    # How it leaves is injectable, so that what it says on the way out can be
    # proved by calling the handler rather than by killing the process - a
    # handler nothing has ever run is a handler nobody knows works.
    my $leave = $option->{leave} || sub { exit 0 };

    # How it replaces itself, injectable for the same reason leaving is: a
    # restart proved by calling the handler is a restart somebody has watched,
    # and one proved by execing the test suite is not.
    my $restarter = $option->{restarter} || \&_restart_into;
    for my $signal (qw(INT TERM HUP)) {
        $SIG{$signal} = sub {
            _police_goodbye( $tira, $signal );
            _police_release_singleton( $store, %{ $option->{singleton} // {} } );
            $leave->();
        };
    }
    my $done = 0;

    # Which board this round is about, so the bridge can be told. Set inside the
    # eval that discovers it and cleared at the top of every round, because a
    # round that could not read the board must not write a line about the last
    # one.
    my $watched_board;
    while ( !defined $rounds || $done < $rounds ) {
        $done++;
        undef $watched_board;
        # Gathered every round, not once at the start: a container that comes up
        # an hour into a watch is exactly the kind of thing this is for.
        my $result = eval {
            my $watching = $tira->discover_project( %{$args} );
            $watched_board = $watching;
            $tira->police_pass( %{$args}, store => $store,
                world => _police_world( tira => $tira, project => $watching ) );
        };
        if ( !$result ) {
            # Transient trouble is not a reason to stop watching.
            print {*STDERR} 'police could not read the board: ' . ( $@ || 'unknown' ) . "\n";
        }
        else {
            $tira->bridge_write( store => $store, project => $watched_board,
                violations => $result->{violations}, settled => $result->{settled},
            upgraded => $result->{upgraded} );
            print {*STDERR} map { "$_\n" } @{ $result->{terminal} };
        }
        # Into the code that is installed, between rounds.
        #
        # The machinery has existed since the dashboard needed it and nothing
        # here ever called it, so a police left running through a release kept
        # the rulebook it started with: rules that shipped since were not
        # evaluated, wording that had been corrected was still printed, and it
        # said nothing about either - a watcher reading old rules looks exactly
        # like a watcher reading new ones. Reported by the owner on 2026-08-15,
        # and measured on this project's own board an hour later, where a fix
        # that had shipped, passed its gate and reached origin went on being
        # contradicted by the police still running the previous version.
        #
        # Between rounds, never during a pass: police writes the bridge and the
        # enforcement ledger, and a pass cut in half would leave a violation
        # counted and unsaid, or said and uncounted.
        #
        # _restart_if_updated asks whether the code differs rather than whether
        # a label moved, which is what stops this looping - exec loads the same
        # module again and disagrees with .env again, and four dashboards did
        # exactly that every sixty seconds for twenty hours.
        # Once. _restart_into execs and never comes back, so in a running
        # police this can only happen once by construction - but if it ever
        # returns, whether because exec failed or because a caller handed in
        # something that does not exec, carrying on would try again every
        # interval for ever. That is the shape of the loop this whole mechanism
        # was built to avoid, so a restart that returns ends the watch instead:
        # a police that has stopped is visible, and one restarting on a timer
        # is not.
        last
          if defined $watched_board
          && _restart_if_updated( $restarter, 'police', undef, $watched_board );

        # And the board it watches, which cannot do this for itself: under a
        # pre-forked server the process that notices a new version is a
        # worker, and a worker cannot replace the board. Police is outside
        # the pool and owns no socket, so it sends the master a HUP and the
        # workers come back on the installed code, finishing what they hold
        # first. Signalled once per release, never per pass. TKT-565.
        my %hup = %{ $option->{dashboard} // {} };
        if ( !exists $hup{port} && defined $watched_board ) {
            $hup{port} = eval { $tira->project_show( project => $watched_board )->{dashboard}{port} };
        }
        my $board = _dashboard_hup_if_stale( $store, %hup );
        print {*STDERR} "police: told the dashboard (pid $board->{pid}) to reload into $board->{version}\n"
          if $board->{hupped};

        $wait->($interval);
    }
    return { rounds => $done };
}

# Split out from the signal handler so that what police says on its way out can
# be called and checked, rather than only reached by killing the process.
sub _police_goodbye {
    my ( $tira, $signal ) = @_;
    print {*STDERR} $tira->police_farewell( reason => "signal $signal" ) . "\n";
    return 1;
}

# Where the singleton claim lives - beside the enforcement ledger itself,
# since both are per-store, not per-project.
sub _police_singleton_path {
    my ($store) = @_;
    return File::Spec->catfile( $store, '.police.pid' );
}

# Which process is holding a port, asked of the kernel rather than of a file
# somebody wrote earlier. Michael's own point on TKT-565: "Could that be more
# reliable to find the pid on demand by checking which is the master process
# by the port number?" - and it is, because a pidfile goes stale, survives a
# crash, and can name a pid the machine has since reused, while a listening
# socket is the truth at the moment it is asked.
#
# Read straight out of /proc, so Tira still invokes no shell: the port's
# listening socket gives an inode in /proc/net/tcp, and the process holding
# it is the one with that inode among its open descriptors. Anywhere without
# /proc this answers undef, which the caller treats as "no board found" and
# refuses on - the same way it treats every other uncertainty.
sub _listening_pid {
    my ( $port, %opts ) = @_;
    return undef if !defined $port || $port !~ /\A[0-9]+\z/;
    my $proc = $opts{proc} // '/proc';
    my $hex = sprintf '%04X', $port;

    my %inode;
    for my $table (qw(net/tcp net/tcp6)) {
        open my $fh, '<', File::Spec->catfile( $proc, $table ) or next;
        while ( my $line = <$fh> ) {

            # local_address is host:port in hex, and 0A is LISTEN. Anything
            # else on the same port is a connection to it, not the server.
            # After the 0A come tx:rx, tr:when, retrnsmt, uid and timeout
            # before the inode. Counting one field short here captured the
            # timeout - always 0 - and matched nothing, which looked exactly
            # like "no board is listening".
            next if $line !~ /\A\s*\d+:\s+\S+:$hex\s+\S+\s+0A\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)/;
            $inode{$1} = 1;
        }
        close $fh;
    }
    return undef if !%inode;

    opendir my $dh, $proc or return undef;
    my @pids = sort { $a <=> $b } grep { /\A[0-9]+\z/ } readdir $dh;
    closedir $dh;

    # Everyone holding it, not the first one found. A pre-forked server's
    # master and every one of its workers share the listening socket - all
    # six processes on the owner's own board held inode 35794984 - so the
    # first match is simply the lowest pid, which is the master only because
    # it happened to be created first. Once pids wrap past pid_max a worker
    # can be numbered below its own master, and a container's pid_max is far
    # smaller than a host's. Signalling a worker would reload that one worker
    # onto the new code and leave the rest on the old, with the once-per
    # -release mark written anyway: a board serving two versions at once,
    # silently and permanently. TKT-567.
    my @holding;
    for my $pid (@pids) {
        opendir my $fds, File::Spec->catdir( $proc, $pid, 'fd' ) or next;
        my @fd = grep { /\A[0-9]+\z/ } readdir $fds;
        closedir $fds;
        for my $fd (@fd) {
            my $target = readlink File::Spec->catfile( $proc, $pid, 'fd', $fd );
            next if !defined $target || $target !~ /\Asocket:\[(\d+)\]\z/;
            next if !$inode{$1};
            push @holding, 0 + $pid;
            last;
        }
    }
    return undef if !@holding;
    return $holding[0] if @holding == 1;

    # The master is the one nothing else in the set fathered: every worker's
    # parent is the master, and the master's parent is whatever launched the
    # board. Structural, so it holds whatever order the pids happen to fall
    # in. Exactly one such process, or none - two would mean this is not the
    # process tree we think it is, and refusing beats guessing when guessing
    # wrong means signalling a worker.
    my %in_set = map { $_ => 1 } @holding;
    my @rootmost = grep {
        my $ppid = _parent_of_pid( $_, proc => $proc );
        !defined $ppid || !$in_set{$ppid};
    } @holding;
    return @rootmost == 1 ? $rootmost[0] : undef;
}

# A process's parent, from the same shell-free source as everything else
# here. Undef when it cannot be read, which the caller treats as "not in the
# set" - the safe direction, since it can only ever make a pid look more
# rootmost, and two rootmost candidates refuse rather than pick. TKT-567.
sub _parent_of_pid {
    my ( $pid, %opts ) = @_;
    my $proc = $opts{proc} // '/proc';
    open my $fh, '<', File::Spec->catfile( $proc, $pid, 'status' ) or return undef;
    while ( my $line = <$fh> ) {
        next if $line !~ /\APPid:\s*(\d+)/;
        close $fh;
        return 0 + $1;
    }
    close $fh;
    return undef;
}

# What a process was launched as, read from the same shell-free source the
# port lookup already uses. The arguments are NUL-separated in /proc, so
# they are joined with spaces to be matched as one string. Anywhere without
# /proc this answers undef, and undef refuses. TKT-566.
sub _command_of_pid {
    my ( $pid, %opts ) = @_;
    return undef if !defined $pid || $pid !~ /\A[0-9]+\z/;
    my $proc = $opts{proc} // '/proc';
    open my $fh, '<:raw', File::Spec->catfile( $proc, $pid, 'cmdline' ) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return undef if !defined $raw || $raw eq '';
    $raw =~ s/\0/ /g;
    $raw =~ s/\s+\z//;
    return $raw;
}

# Where the last version police signalled a board about is remembered, so it
# signals once per release rather than once per pass. Signalling every pass
# is the exact shape of the loop this whole mechanism was built to avoid -
# four boards did it every sixty-five seconds for twenty hours.
sub _dashboard_hup_mark_path {
    my ($store) = @_;
    return File::Spec->catfile( $store, '.dashboard.huped' );
}

# HUP, not a kill. Tira serves a .psgi FILE PATH rather than an in-memory
# coderef precisely so that Starman's HUP re-forks workers which read the
# modules from disk again - proved when that was chosen, and proved again
# here before this was built: a two-worker Starman on a .psgi reading a
# version from a file served "one", the file changed, the master got HUP,
# and it served "two" from fresh worker pids. Starman's own documentation
# says the same, and only --preload-app breaks it, which Tira does not use.
#
# The first design of this card stopped the master and launched a
# replacement. Michael asked the question that ended it: "After master
# process killed. The children still survived. Have you think of this side
# effect too?" - kill-and-relaunch has to get orphan reaping, port-free
# timing and a correct relaunch command all right, and HUP has none of those
# failure modes and drops no request, because workers finish what they are
# holding before they are replaced.
#
# Refusing is the default, and every refusal names itself: a board on
# slightly old code is a working board.
sub _dashboard_hup_if_stale {
    my ( $store, %opts ) = @_;
    my $port = $opts{port};
    return { hupped => 0, refused => 'no-port' } if !defined $port || $port !~ /\A[0-9]+\z/;

    my $on_disk = exists $opts{on_disk} ? $opts{on_disk} : _version_on_disk();
    return { hupped => 0, refused => 'unknown-version' } if !defined $on_disk;

    my $path = _dashboard_hup_mark_path($store);
    if ( open my $fh, '<', $path ) {
        my $done = do { local $/; <$fh> };
        close $fh;
        $done =~ s/\s+//g if defined $done;
        return { hupped => 0, refused => 'already-current' }
          if defined $done && length $done && $done eq $on_disk;
    }

    my $find = $opts{listening} || sub { _listening_pid( $_[0] ) };
    my $pid = $find->($port);
    return { hupped => 0, refused => 'no-board' } if !defined $pid;

    # Whoever holds the port is not necessarily the board, and SIGHUP's
    # default disposition is Term - so signalling a stranger that installs
    # no handler kills it outright. Proved rather than assumed: a plain
    # `perl -e 'sleep 300'` given HUP died with "Hangup". The board port is
    # a stable configured number, so any time the board is down and another
    # program has taken it, this would be a real process killed by a
    # supervisor that was only trying to reload a dashboard.
    #
    # What is checked is that it is a Starman, not that it is provably this
    # board. Two facts from the owner's own running board forced that:
    # Starman rewrites $0, so a live master's command line reads "starman
    # master" and names neither dashboard.psgi nor the command that started
    # it - an earlier version of this check looked for dashboard.psgi and
    # would have refused every genuine board while looking perfectly safe -
    # and assigning $0 on Linux clobbers the environ region too, so there is
    # no TIRA_DASHBOARD_ROOT left to read either. The parent is no help
    # (d2 tira.dashboard execs into Starman rather than forking, so the
    # master's parent is whatever shell launched it).
    #
    # A Starman is enough, because this guard exists to stop the one thing
    # that is actually destructive: signalling a process with no HUP handler,
    # which SIGHUP's default disposition then terminates. Every Starman
    # handles HUP, so the worst a misidentified one suffers is a graceful
    # reload of its own workers. The port comes from this board's own
    # project.yml, which is the real identifier - the owner's point exactly:
    # "Each application only hold their own port".
    #
    # An unreadable command line refuses like an unrecognised one, because
    # "cannot tell" is not "is safe to signal". TKT-566.
    my $identify = $opts{identify} || sub { _command_of_pid( $_[0] ) };
    my $command = $identify->($pid);
    return { hupped => 0, refused => 'not-a-board' }
      if !defined $command || $command !~ /\bstarman\b/i;

    my $signal = $opts{hup} || sub { kill 'HUP', $_[0] };
    $signal->($pid);

    File::Path::make_path($store) if !-d $store;
    if ( open my $fh, '>', $path ) {
        print {$fh} $on_disk;
        close $fh;
    }
    return { hupped => 1, pid => $pid, version => $on_disk };
}

# The claim: read whoever was there before, kill them if they are still
# alive, then write our own pid over theirs. pid/alive/kill are all
# injectable - the same shape leave/restarter/sleeper already use in
# _police_follow - so this is provable without spawning or signalling a
# real OS process. TKT-492.
sub _police_claim_singleton {
    my ( $store, %opts ) = @_;
    File::Path::make_path($store) if !-d $store;
    my $path = _police_singleton_path($store);
    my $my_pid = $opts{pid} // $$;
    my $alive = $opts{alive} || sub { return kill 0, $_[0] };
    my $kill_previous = $opts{kill} || sub { kill 'TERM', $_[0] };

    my $killed;
    if ( open my $fh, '<', $path ) {
        my $previous = do { local $/; <$fh> };
        close $fh;
        $previous =~ s/\s+//g;
        if ( length $previous && $previous ne $my_pid && $alive->($previous) ) {
            $kill_previous->($previous);
            $killed = $previous;
        }
    }
    open my $fh, '>', $path or die "Cannot claim the police singleton at '$path': $!\n";
    print {$fh} $my_pid;
    close $fh;
    return { claimed => $my_pid, killed => $killed };
}

# The pid file is this process's own claim, so a clean exit removes it
# rather than leaving a stale entry the next daemon's alive-check has to
# reason past. A daemon that dies uncleanly (kill -9, a crash) leaves the
# file behind - the next claim's alive-check still handles that safely,
# since a dead pid answers false and nothing is killed.
sub _police_release_singleton {
    my ( $store, %opts ) = @_;
    my $path = _police_singleton_path($store);
    my $remove = $opts{unlink} || sub { unlink $_[0] };
    $remove->($path);
    return;
}

sub _policy_help {
    my (%args) = @_;
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return '';
    my $doc = $args{document}
      // File::Spec->catfile( dirname( dirname( dirname($1) ) ), 'docs', 'POLICIES.md' );
    if ( -f $doc && open my $fh, '<:raw', $doc ) {
        my $text = do { local $/; <$fh> };
        close $fh;
        return $text;
    }
    return _policy_help_fallback();
}

# Said when the document is not there. An installation missing its docs should
# still be able to tell an agent what exists, rather than answering nothing.
sub _policy_help_fallback {
    return join "\n",
      'Tira policies',
      '',
      'Rules: ' . join( ', ', @{ Tira::policy_rules() } ),
      'Actions: ' . join( ', ', @{ Tira::policy_actions() } ),
      '',
      'Declare one:  d2 tira.policy.add --rule <rule> --action <action> [parameters]',
      'See them:     d2 tira.policy.list',
      'Watch:        d2 tira.police            (the owner runs this)',
      'Listen:       d2 tira.policy.bridge     (the agent runs this)',
      '';
}

sub _text_input {
    my ( $file, %args ) = @_;
    my $fh;
    if ( $file eq '-' ) {
        $fh = *STDIN;
    }
    else {
        open $fh, '<:raw', $file or die "Cannot read '$file': $!\n";
    }
    my $content = do { local $/; <$fh> };
    close $fh if $file ne '-';
    return $args{utf8} ? decode( 'UTF-8', $content, FB_CROAK ) : $content;
}

sub _json_array_input {
    my ($file) = @_;
    my $data = Tira::json_decode( _text_input($file) );
    die "Replacement input must be a JSON array\n" if ref($data) ne 'ARRAY';
    return $data;
}

# What supplies the thing a refusal says is missing.
#
# The engine raises these messages and has no notion of a command line, which
# is why they name a thing rather than a flag - "Record reference is required"
# from forty commands, and not one of them says --ref. Measured by running
# every entrypoint with no arguments: 83 refusals that name no option at all.
# The standard is this project's own, and the owner named it: "Policy rule
# card-sandbox-missing needs --enter" takes no guessing.
#
# So the translation lives here, at the boundary where flag names already live,
# and the engine keeps no table of them. Declared rather than derived, and held
# honest by a guard that runs every entrypoint: a message reworded out of this
# table stops naming its option, and the guard says so. TKT-268.
# Two shapes, because two things can be wrong. A thing that is missing is
# supplied by an option; a value that is wrong came in through one, and telling
# somebody to supply what they just supplied would be its own kind of useless.
my %SUPPLIED_BY = (
    'Record reference is required'         => [ 'ref',      'supply it with' ],
    'A card reference is required'         => [ 'ref',      'supply it with' ],
    'A question id is required'            => [ 'id',       'supply it with' ],
    'An attachment reference is required'  => [ 'ref',      'supply it with' ],
    'Record title is required'             => [ 'title',    'supply it with' ],
    'Project name is required'             => [ 'name',     'supply it with' ],
    'Project person is required'           => [ 'person',   'supply it with' ],
    'Person id is required'                => [ 'id',       'supply it with' ],
    'Password is required'                 => [ 'password', 'supply it with' ],
    'Import file is required'              => [ 'file',     'supply it with' ],
    'Replacement pattern is required'      => [ 'pattern',  'supply it with' ],
    'Link type names are required'         => [ 'outward',  'supply it with' ],
    'Checklist item is required'           => [ 'item',     'supply it with' ],
    'Checklist item or status is required' => [ 'item',     'supply it with' ],
    'A warning message is required'        => [ 'message',  'supply it with' ],
    'Gate annotation note is required'     => [ 'note',     'supply it with' ],
    'Evidence annotation note is required' => [ 'note',     'supply it with' ],
    'A question needs some text'           => [ 'text',     'supply it with' ],
    'An answer needs some text'            => [ 'text',     'supply it with' ],
    'How many seconds?'                    => [ 'seconds',  'supply it with' ],
    'A move needs to say who is making it' => [ 'author',   'supply it with' ],

    # Given rather than missing: the option carried a value the command will
    # not take, so it is named rather than asked for.
    'Invalid column name'                  => [ 'name',         'the option is' ],
    'Invalid attachment SHA'               => [ 'sha',          'the option is' ],
    'Invalid gate result'                  => [ 'result',       'the option is' ],
    'Unknown policy rule'                  => [ 'rule',         'the option is' ],
    "Policy '' not found"                  => [ 'id',           'the option is' ],
    'A column layout must be JSON'         => [ 'columns-json', 'the option is' ],
);

sub _names_the_option {
    my ($message) = @_;
    for my $said ( sort keys %SUPPLIED_BY ) {
        next if index( $message, $said ) < 0;
        my ( $flag, $phrase ) = @{ $SUPPLIED_BY{$said} };
        return $message if $message =~ /--\Q$flag\E\b/;
        return "$message - $phrase --$flag";
    }
    return $message;
}

# Every long name a command's own @spec actually answers to - both sides of
# a '|' alias, with Getopt::Long's value/repeat/negation syntax (=s, =s@,
# :i, !) stripped back to the bare flag. Built from the same @spec the
# parse just used, so a suggestion can never name a flag the command does
# not really have.
sub _declared_option_names {
    my ($spec) = @_;
    my @names;
    for ( my $i = 0; $i < @{$spec}; $i += 2 ) {
        ( my $names = $spec->[$i] ) =~ s/[=:!].*//;
        push @names, split /\|/, $names;
    }
    return \@names;
}

# Levenshtein distance, the standard three-operation edit count - the same
# measure a spelling-correction "did you mean" is built on anywhere it
# exists. Iterative, not recursive: the option lists here are short enough
# (a low hundred, at most) that clarity wins over avoiding an O(n*m) table.
sub _edit_distance {
    my ( $left, $right ) = @_;
    my @prev = ( 0 .. length $right );
    for my $i ( 1 .. length $left ) {
        my @row = ($i);
        for my $j ( 1 .. length $right ) {
            if ( substr( $left, $i - 1, 1 ) eq substr( $right, $j - 1, 1 ) ) {
                $row[$j] = $prev[ $j - 1 ];
                next;
            }
            my $least = $prev[$j];
            $least = $row[ $j - 1 ]     if $row[ $j - 1 ] < $least;
            $least = $prev[ $j - 1 ]    if $prev[ $j - 1 ] < $least;
            $row[$j] = 1 + $least;
        }
        @prev = @row;
    }
    return $prev[-1];
}

# What an unknown option gets, now: named the way "Command not found" names
# a mistyped verb - the closest declared names this command actually
# answers to, not silence past "Invalid command-line options". TKT-298.
sub _unknown_option_message {
    my ( $unknown, $spec ) = @_;
    my $known = _declared_option_names($spec);
    my @lines;
    for my $bad ( @{$unknown} ) {
        my %distance = map { $_ => _edit_distance( $bad, $_ ) } @{$known};
        my @near = sort { $distance{$a} <=> $distance{$b} || $a cmp $b }
          grep { $distance{$_} <= 3 } keys %distance;
        push @lines, "Unknown option: $bad";
        push @lines, 'Did you mean:', ( map { "  --$_" } @near[ 0 .. ( $#near > 2 ? 2 : $#near ) ] )
          if @near;
    }
    return join( "\n", @lines );
}

sub _error {
    my ( $tira, $output, $message ) = @_;
    $message =~ s/\s+\z//;
    $message = _names_the_option($message);
    my $formatted = eval { $tira->format_output( { error => $message }, output => $output ) };
    $formatted = Tira::json_object()->canonical->pretty->encode( { error => $message } ) if !defined $formatted;
    print STDERR _utf8_bytes($formatted);
    return 2;
}

sub _utf8_bytes {
    my ($text) = @_;
    return utf8::is_utf8($text) ? encode_utf8($text) : $text;
}

# What each record verb takes, so asking a command how to use it does not
# answer about a different one.
#
# Every record command shared one line and the line named create, so
# tira.ticket.move --help said 'Usage: dashboard tira.ticket.create --title
# TITLE'. 21 of the 24 record verbs answered about a command that was not the
# one asked about; the three that were right were the three creates. It adapted
# the board - tira.sow.list answered with tira.sow.create - which is why it read
# as considered rather than as a fallback, and why it stood. A wrong answer that
# looks specific is not questioned.
#
# The shapes are the ones verified against the running commands when the command
# reference was given its record section, rather than written from memory: that
# is how discard was found to take no reason. TKT-235.
my %RECORD_USAGE = (
    create  => '--title TEXT [record field arguments]',
    show    => '--ref REF [--fields LIST] [--brief|--full]',
    list    => '[--column SLUG] [--assignee ID] [--fields LIST] [--count]',
    update  => '--ref REF [record field arguments]',
    move    => '--ref REF --column SLUG [--author NAME]',
    clone   => '--ref REF --title TEXT',
    discard => '--ref REF',
    restore => '--ref REF [--column SLUG]',
    missing => '--ref REF',
);

# The commands that cannot work without a type. Their usage line named no
# option at all, so a reader who checked it before running anything was told
# the opposite of the truth: that the command took nothing. TKT-215.
my %NEEDS_TYPE = map { $_ => 1 }
  qw(board.refs board.show column.sync column.update);

# SKILLS.md carries a full usage line for every command it documents - the
# same catalogue docs-match-code already holds every shipped command to - and
# it says more than the bare "[options]" _usage() answered with on its own.
# Read once and cached, relative to this module's own file rather than to
# whichever cli/ script happens to be running, so the answer does not depend
# on how the command was reached. TKT-343.
my $SKILLS_TEXT;

sub _skills_usage_line {
    my ($command) = @_;
    if ( !defined $SKILLS_TEXT ) {
        my $path = File::Spec->catfile( dirname(__FILE__), '..', '..', 'SKILLS.md' );
        local $/;
        if ( open my $fh, '<:raw', $path ) {
            $SKILLS_TEXT = <$fh>;
            close $fh;
        }
        $SKILLS_TEXT //= '';
    }
    my ($rest) = $SKILLS_TEXT =~ /^tira\.\Q$command\E\s+(\S.*)$/m;
    return $rest;
}

sub _usage {
    my ( $command, $type ) = @_;
    return "Usage: dashboard tira.project.create --name NAME [--dir DIR] [-o toon|json|human]\n"
      if $command eq 'project.create';

    if ( $NEEDS_TYPE{ $command // '' } ) {
        my $known = _skills_usage_line($command);
        return "Usage: dashboard tira.$command $known\n" if defined $known;
        return "Usage: dashboard tira.$command --type ticket|epic|sow [options] [-o toon|json|human]\n";
    }

    if ( defined $type ) {
        my ($verb) = ( $command // '' ) =~ /\.([a-z]+)\z/;

        # SKILLS.md documents a typed verb two ways - a concrete line per
        # type ("tira.ticket.create ...") or one generic line for all three
        # ("tira.<type>.list ...") - and %RECORD_USAGE has drifted from both
        # without anybody noticing, because this branch never checked either
        # one. Tried in that order, so a concrete line wins over the generic
        # placeholder if a command ever carries both. TKT-418.
        my $known = _skills_usage_line("$type.$verb") // _skills_usage_line("<type>.$verb");
        return "Usage: dashboard tira.$type.$verb $known\n" if defined $known;

        my $takes = $RECORD_USAGE{ $verb // '' };
        return "Usage: dashboard tira.$type.$verb $takes [-o toon|json|human]\n"
          if defined $takes;

        # A record verb this does not know is named rather than described,
        # which is still an answer about the command that was asked.
        return "Usage: dashboard tira.$type." . ( $verb // 'command' )
          . " [options] [-o toon|json|human]\n";
    }

    my $known = _skills_usage_line($command);
    return "Usage: dashboard tira.$command $known\n" if defined $known;
    return "Usage: dashboard tira.$command [options] [-o toon|json|human]\n";
}

1;

__END__

=head1 NAME

Tira::CLI - Shared command boundary for Tira DD commands

=head1 DESCRIPTION

Parses the common project and record metadata options, invokes L<Tira>, and
applies the TOON-first output and structured error contract. Project-location
selection is intentionally omitted from user-facing help. Text input is decoded
strictly as UTF-8 and structured output is emitted as UTF-8 bytes; attachment
content remains raw. Dashboard commands additionally support self-contained
HTML and validated Dancer2 browser serving.

=head1 METHODS

=head2 run

Runs one named command against an argument array and returns its process exit
code without calling C<exit>, allowing direct unit testing.

C<project.new> and C<onboard> share one branch, and it validates C<--mode>
before C<project_new> is called rather than after. The order is the point:
C<project_mode> runs once the project exists, so an invalid value used to
produce a failed command and a fully created project at the same time, with
nothing to roll back. The accepted values come from
C<onboarding_questions()> rather than being written out here, so the two
cannot disagree.

=head2 browser_providers

Returns the flat hash of named coderefs L<Tira::DashboardWeb> requires to
build its Dancer2 app - one entry per route, so a browser mutation can never
drift from the engine's own validated command surface. TKT-516 added
C<tasklist>, C<tasklist_add>, C<tasklist_update>, C<tasklist_next>,
C<tasklist_shift>, C<tasklist_pop>, C<tasklist_unshift>, C<tasklist_slice>,
C<tasklist_remove>, C<tasklist_import>, C<tasklist_prune>,
C<tasklist_task_attach_add>, C<tasklist_task_attach_discard>,
C<tasklist_task_ref_link>, and C<tasklist_task_ref_unlink>, giving the
browser dashboard's Task List section full parity with C<tira.tasklist.*>.
TKT-540: C<tasklist_update>, C<tasklist_remove>, C<tasklist_task_attach_add>,
C<tasklist_task_attach_discard>, C<tasklist_task_ref_link>, and
C<tasklist_task_ref_unlink> now forward the payload's C<session> field to
the engine, matching the other eight tasklist providers - previously these
six silently dropped it, so a session switched in the dashboard's own
session box could view an item it could not then mutate once TKT-538 began
enforcing session ownership.

=head2 run's onboard -o browser branch

TKT-517: C<-o browser> is accepted for the C<onboard> command as well as
C<dashboard>. Rather than the interactive STDIN wizard, C<run> starts a
disposable L<Tira::OnboardWeb> server (via the injectable
C<onboard_browser_server> seam, C<_serve_onboard_browser> by default) on
C<127.0.0.1> and a dynamically-picked free port (C<_free_port>), unless an
explicit C<-o browser=host:port> was given. Its C<create> provider calls
back into the exact C<_invoke($tira, 'onboard', undef, \%merged)> dispatch
the interactive wizard's own answers reach, so nothing forks into a second,
divergent project-creation path. TKT-527: an explicit C<-o browser=0.0.0.0:PORT>
is refused for C<onboard> specifically (naming why) - this server has no
login, so C<0.0.0.0> would be a genuinely unauthenticated project-creation
endpoint; C<127.0.0.1>/C<localhost>/the plain default are unaffected, and
C<dashboard>'s own C<0.0.0.0> handling (a separate branch) is untouched.

=cut
