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
    my $output = 'toon';
    my ( $name, $dir, $title, $description, $project, $help );

    my $parsed = GetOptionsFromArray(
        $argv,
        'name=s'        => \$name,
        'dir=s'         => \$dir,
        'title=s'       => \$title,
        'description=s' => \$description,
        'project=s'     => \$project,
        'output|o=s'    => \$output,
        'help'          => \$help,
    );
    return _error( $tira, $output, 'Invalid command-line options' ) if !$parsed || @{$argv};

    if ($help) {
        print _usage( $command, $type );
        return 0;
    }

    my $result;
    my $ok = eval {
        if ( $command eq 'project.create' ) {
            $result = $tira->create_project(
                name => $name,
                dir  => defined $dir ? $dir : '.',
            );
        }
        elsif ( $command eq 'record.create' ) {
            my $project_dir = defined $project ? $project : $ENV{TIRA_HOME};
            $result = $tira->create_record(
                type        => $type,
                title       => $title,
                description => $description,
                defined $project_dir ? ( project => $project_dir ) : (),
            );
        }
        else {
            die "Unsupported Tira command '$command'\n";
        }
        1;
    };
    return _error( $tira, $output, $@ || 'Unknown Tira failure' ) if !$ok;

    my $formatted = eval { $tira->format_output( $result, output => $output ) };
    return _error( $tira, 'toon', $@ || 'Unable to format output' ) if !defined $formatted;
    print $formatted;
    return 0;
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
    return "Usage: dashboard tira.$type.create --title TITLE [--description TEXT] [--project DIR] [-o toon|json|human]\n"
      . "       --project overrides TIRA_HOME; otherwise Tira discovers from the current directory.\n";
}

1;

__END__

=head1 NAME

Tira::CLI - Shared command boundary for Tira DD commands

=head1 DESCRIPTION

Parses the common project and record creation options, invokes L<Tira>, and
applies the TOON-first output and structured error contract. Record commands
use C<--project>, then C<TIRA_HOME>, then upward discovery in precedence order.

=head1 METHODS

=head2 run

Runs one named command against an argument array and returns its process exit
code without calling C<exit>, allowing direct unit testing.

=cut
