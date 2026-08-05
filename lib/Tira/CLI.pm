package Tira::CLI;

use strict;
use warnings;

use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP ();
use Tira;

sub run {
    my ( $class, %args ) = @_;
    my $command = $args{command} // '';
    my $type = $args{type};
    my $argv = $args{argv} || [];
    my $tira = $args{tira} || Tira->new;
    my %option = ( output => 'toon' );
    my @repeatable = qw(key_detail deliverable scope_in scope_out acceptance test_step bdd atdd assignee person attach);

    my $parsed = GetOptionsFromArray(
        $argv,
        'name=s' => \$option{name}, 'dir=s' => \$option{dir}, 'title=s' => \$option{title},
        'description=s' => \$option{description}, 'project=s' => \$option{project},
        'output|o=s' => \$option{output}, 'help' => \$option{help},
        'id=s' => \$option{id}, 'email=s' => \$option{email},
        'outward=s' => \$option{outward}, 'inward=s' => \$option{inward},
        'type=s' => \$option{type}, 'label=s' => \$option{label},
        'after=s' => \$option{after}, 'before=s' => \$option{before},
        'new-name=s' => \$option{new_name}, 'prefix=s' => \$option{prefix},
        'digits=i' => \$option{digits}, 'ref=s' => \$option{ref},
        'column=s' => \$option{column}, 'parent=s' => \$option{parent},
        'child=s' => \$option{child},
        'text=s' => \$option{text}, 'problem=s' => \$option{problem_or_feature},
        'solution-needed=s' => \$option{solution_needed}, 'source=s' => \$option{source},
        'from=s' => \$option{from}, 'to=s' => \$option{to},
        'author=s' => \$option{author}, 'file=s' => \$option{file},
        'format=s' => \$option{format}, 'comment=s' => \$option{comment},
        'sha=s' => \$option{sha}, 'extension=s' => \$option{extension},
        'summary=s' => \$option{summary}, 'uri=s' => \$option{uri},
        'gate=s' => \$option{gate}, 'result=s' => \$option{result},
        'details=s' => \$option{details},
        'repair-columns' => \$option{repair_columns}, 'apply' => \$option{apply},
        'recursive' => \$option{recursive}, 'include-deleted' => \$option{include_deleted},
        'include-discard' => \$option{include_discard},
        'key-detail=s@' => \$option{key_details}, 'deliverable=s@' => \$option{deliverables},
        'scope-in=s@' => \$option{scope_in}, 'scope-out=s@' => \$option{scope_out},
        'acceptance=s@' => \$option{acceptance}, 'test-step=s@' => \$option{test_steps},
        'bdd=s@' => \$option{bdd}, 'atdd=s@' => \$option{atdd},
        'assignee=s@' => \$option{assignees}, 'person=s@' => \$option{people},
        'attach=s@' => \$option{attach},
        'set-key-details=s' => \$option{set_key_details},
        'set-deliverables=s' => \$option{set_deliverables},
        'set-acceptance=s' => \$option{set_acceptance},
        'set-test-steps=s' => \$option{set_test_steps},
        'set-bdd=s' => \$option{set_bdd}, 'set-atdd=s' => \$option{set_atdd},
    );
    return _error( $tira, $option{output}, 'Invalid command-line options' ) if !$parsed || @{$argv};

    if ( $option{help} ) {
        print _usage( $command, $type );
        return 0;
    }

    $option{project} = $ENV{TIRA_HOME} if !defined $option{project} && defined $ENV{TIRA_HOME};

    my $result;
    my $ok = eval {
        $result = _invoke( $tira, $command, $type, \%option );
        1;
    };
    return _error( $tira, $option{output}, $@ || 'Unknown Tira failure' ) if !$ok;

    if ( $command eq 'attachment.get' ) {
        if ( $option{output} eq 'path' ) {
            print "$result->{path}\n";
            return 0;
        }
        print $result->{content};
        return $result->{deleted} ? 1 : 0;
    }

    my $formatted = eval { $tira->format_output( $result, output => $option{output} ) };
    return _error( $tira, 'toon', $@ || 'Unable to format output' ) if !defined $formatted;
    print $formatted;
    return 0;
}

sub _invoke {
    my ( $tira, $command, $record_type, $option ) = @_;
    my %args = %{$option};
    delete @args{qw(output help apply repair_columns recursive include_deleted include_discard attach set_key_details set_deliverables set_acceptance set_test_steps set_bdd set_atdd)};
    $args{type} = $record_type if defined $record_type;
    my %sets = (
        set_key_details => 'key_details', set_deliverables => 'deliverables',
        set_acceptance => 'acceptance', set_test_steps => 'test_steps',
        set_bdd => 'bdd', set_atdd => 'atdd',
    );
    for my $set ( keys %sets ) {
        next if !defined $option->{$set};
        die "Cannot combine append and replacement for '$sets{$set}'\n" if defined $args{ $sets{$set} };
        $args{ $sets{$set} } = _json_array_input( $option->{$set} );
    }

    return $tira->create_project( name => $option->{name}, dir => $option->{dir} // '.' ) if $command eq 'project.create';
    return $tira->create_record(%args) if $command eq 'record.create';
    return $tira->project_show(%args) if $command eq 'project.show';
    return $tira->project_update(%args) if $command eq 'project.update';
    return $tira->person_list(%args) if $command eq 'project.people.list';
    return $tira->person_add(%args) if $command eq 'project.people.add';
    return $tira->person_update(%args) if $command eq 'project.people.update';
    return $tira->person_remove(%args) if $command eq 'project.people.remove';
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
    return $tira->column_sync( %args, apply => $option->{apply} ) if $command eq 'column.sync';

    if ( $command =~ /\Arecord\.(show|list|update|move|discard|restore|clone)\z/ ) {
        my $action = $1;
        return $tira->record_show(%args) if $action eq 'show';
        return $tira->record_list(%args) if $action eq 'list';
        return $tira->record_update(%args) if $action eq 'update';
        return $tira->record_move(%args) if $action eq 'move';
        return $tira->record_discard(%args) if $action eq 'discard';
        return $tira->record_restore(%args) if $action eq 'restore';
        return $tira->record_clone(%args);
    }

    my %method = (
        'hierarchy.link' => 'hierarchy_link', 'hierarchy.unlink' => 'hierarchy_unlink', 'hierarchy.show' => 'hierarchy_show',
        'subitem.link' => 'subitem_link', 'subitem.unlink' => 'subitem_unlink',
        'link.add' => 'link_add', 'link.remove' => 'link_remove', 'link.list' => 'link_list',
        'assign.list' => 'assignment_list', 'assign.add' => 'assignment_add',
        'assign.remove' => 'assignment_remove', 'assign.set' => 'assignment_set',
        'comment.list' => 'comment_list', 'comment.add' => 'comment_add',
        'comment.update' => 'comment_update', 'comment.attach' => 'comment_attach',
        'attachment.add' => 'attachment_add', 'attachment.list' => 'attachment_list',
        'attachment.get' => 'attachment_get', 'attachment.remove' => 'attachment_remove',
        'evidence.list' => 'evidence_list', 'evidence.add' => 'evidence_add',
        'gate.list' => 'gate_list', 'gate.add' => 'gate_add',
        'search' => 'search', 'dashboard' => 'dashboard',
    );
    my $method = $method{$command} or die "Unsupported Tira command '$command'\n";
    $args{person} = $option->{people}[0] if $command =~ /\Aassign\.(?:add|remove)\z/ && $option->{people};
    $args{people} = $option->{people} // [] if $command eq 'assign.set';
    $args{recursive} = $option->{recursive} if $command eq 'hierarchy.show';
    $args{include_discard} = $option->{include_discard} if $command eq 'dashboard';
    $args{include_deleted} = $option->{include_deleted} if $command eq 'attachment.list';
    if ( $command =~ /\Acomment\.(?:add|update)\z/ && defined $option->{file} ) {
        die "Use only one of --text or --file\n" if defined $option->{text};
        $args{text} = _text_input( $option->{file} );
    }
    if ( $command eq 'comment.add' && $option->{attach} ) {
        my $comment = $tira->$method(%args);
        $tira->comment_attach( %args, comment => $comment->{id}, file => $_ ) for @{ $option->{attach} };
        return $tira->comment_list(%args)->[-1];
    }
    return $tira->$method(%args);
}

sub _text_input {
    my ($file) = @_;
    my $fh;
    if ( $file eq '-' ) {
        $fh = *STDIN;
    }
    else {
        open $fh, '<:raw', $file or die "Cannot read '$file': $!\n";
    }
    my $content = do { local $/; <$fh> };
    close $fh if $file ne '-';
    return $content;
}

sub _json_array_input {
    my ($file) = @_;
    my $data = JSON::PP::decode_json( _text_input($file) );
    die "Replacement input must be a JSON array\n" if ref($data) ne 'ARRAY';
    return $data;
}

sub _error {
    my ( $tira, $output, $message ) = @_;
    $message =~ s/\s+\z//;
    my $formatted = eval { $tira->format_output( { error => $message }, output => $output ) };
    $formatted = JSON::PP->new->canonical->pretty->encode( { error => $message } ) if !defined $formatted;
    print STDERR $formatted;
    return 2;
}

sub _usage {
    my ( $command, $type ) = @_;
    return "Usage: dashboard tira.project.create --name NAME [--dir DIR] [-o toon|json|human]\n"
      if $command eq 'project.create';
    return "Usage: dashboard tira.$type.create --title TITLE [--description TEXT] [-o toon|json|human]\n"
      if defined $type;
    return "Usage: dashboard tira.$command [options] [-o toon|json|human]\n";
}

1;

__END__

=head1 NAME

Tira::CLI - Shared command boundary for Tira DD commands

=head1 DESCRIPTION

Parses the common project and record creation options, invokes L<Tira>, and
applies the TOON-first output and structured error contract. Project-location
selection is intentionally omitted from user-facing help.

=head1 METHODS

=head2 run

Runs one named command against an argument array and returns its process exit
code without calling C<exit>, allowing direct unit testing.

=cut
