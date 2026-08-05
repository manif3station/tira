package Tira;

use strict;
use warnings;

use Cwd qw(abs_path realpath);
use Data::TOON;
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use YAML::PP;

our $VERSION = '0.01';

my %TYPE_PREFIX = (
    sow    => 'SOW',
    epic   => 'EPC',
    ticket => 'TKT',
);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        clock => $args{clock} || sub { strftime( '%Y-%m-%dT%H:%M:%S%z', localtime ) },
        yaml  => YAML::PP->new( boolean => 'JSON::PP' ),
    }, $class;
}

sub create_project {
    my ( $self, %args ) = @_;
    my $name = $args{name};
    die "Project name is required\n" if !defined $name || $name eq '';
    my $dir = defined $args{dir} && $args{dir} ne '' ? $args{dir} : '.';

    make_path($dir) if !-d $dir;
    my $root = $self->_canonical_path( $dir, "project directory '$dir'" );
    my $data_root = File::Spec->catdir( $root, '.tira' );
    my $project_file = File::Spec->catfile( $data_root, 'project.yml' );
    die "Tira project already exists at '$root'\n" if -f $project_file;

    make_path( $data_root, File::Spec->catdir( $data_root, 'attachments' ) );
    for my $type ( sort keys %TYPE_PREFIX ) {
        my $board = File::Spec->catdir( $data_root, $type );
        make_path(
            File::Spec->catdir( $board, 'backlog' ),
            File::Spec->catdir( $board, 'discard' ),
        );
        $self->_write_yaml(
            File::Spec->catfile( $board, 'config.yml' ),
            {
                prefix      => $TYPE_PREFIX{$type},
                digits      => 3,
                next_number => 1,
                columns     => [
                    { name => 'backlog', label => 'Backlog', protected => JSON::PP::true },
                    { name => 'discard', label => 'Discard', protected => JSON::PP::true },
                ],
            },
        );
    }

    my $created_at = $self->{clock}->();
    $self->_write_yaml(
        $project_file,
        {
            schema_version => 1,
            name           => $name,
            created_at     => $created_at,
            last_updated   => $created_at,
            people         => [],
            link_types     => [
                { outward => 'blocks', inward => 'is-blocked-by', protected => JSON::PP::true },
                { outward => 'clones', inward => 'is-cloned-by', protected => JSON::PP::true },
                { outward => 'duplicates', inward => 'is-duplicated-by', protected => JSON::PP::true },
                { outward => 'relates-to', inward => 'relates-to', protected => JSON::PP::true },
            ],
        },
    );

    return {
        name       => $name,
        root       => $root,
        created_at => $created_at,
    };
}

sub discover_project {
    my ( $self, %args ) = @_;
    my $candidate = defined $args{project} ? $args{project} : ( $args{start} // '.' );
    die "Cannot resolve project path '$candidate'\n" if !-e $candidate;
    my $path = $self->_canonical_path( $candidate, "project path '$candidate'" );
    $path = dirname($path) if -f $path;

    while (1) {
        return $path if -f File::Spec->catfile( $path, '.tira', 'project.yml' );
        my $parent = dirname($path);
        last if $parent eq $path;
        $path = $parent;
    }
    die "No Tira project found from '$candidate'\n";
}

sub create_record {
    my ( $self, %args ) = @_;
    my $type = $args{type} // '';
    die "Unsupported record type '$type'\n" if !exists $TYPE_PREFIX{$type};
    my $title = $args{title};
    die "Record title is required\n" if !defined $title || $title eq '';
    my $root = $self->discover_project(
        defined $args{project} ? ( project => $args{project} ) : ( start => $args{start} // '.' ),
    );
    my $board = File::Spec->catdir( $root, '.tira', $type );

    return $self->_with_project_lock(
        $root,
        sub {
            my $config_path = File::Spec->catfile( $board, 'config.yml' );
            my $config = $self->{yaml}->load_file($config_path);
            my ( $prefix, $digits, $number ) = $self->_validated_counter( $config, $config_path );
            my $ref = sprintf '%s-%0*d', $prefix, $digits, $number;
            my $record_path = File::Spec->catfile( $board, 'backlog', "$ref.json" );
            die "Record '$ref' already exists\n" if -e $record_path;

            my $now = $self->{clock}->();
            my $record = {
                ref                  => $ref,
                type                 => $type,
                title                => $title,
                description          => $args{description} // '',
                key_details          => [],
                problem_or_feature   => '',
                solution_needed      => '',
                deliverables         => [],
                scope                => { included => [], excluded => [] },
                source               => '',
                acceptance_criteria  => [],
                test_steps           => [],
                bdd                  => [],
                atdd                 => [],
                gate_passing_log     => [],
                evidence             => [],
                attachments          => [],
                subtasks             => [],
                linkage              => $self->_empty_linkage($type),
                assignees            => [],
                comments             => [],
                created_at           => $now,
                last_updated         => $now,
            };

            $self->_write_json( $record_path, $record );
            $config->{next_number} = $number + 1;
            eval { $self->_write_yaml( $config_path, $config ); 1 } or do {
                my $error = $@ || 'Unknown counter update failure';
                unlink $record_path;
                die $error;
            };
            return $record;
        },
    );
}

sub format_output {
    my ( $self, $data, %args ) = @_;
    my $output = $args{output} // 'toon';
    return Data::TOON->encode($data) . "\n" if $output eq 'toon';
    return JSON::PP->new->canonical->pretty->encode($data) if $output eq 'json';
    return $self->_markdown($data) if $output eq 'human';
    die "Unsupported output format '$output'\n";
}

sub _empty_linkage {
    my ( $self, $type ) = @_;
    return {
        parent_sow_ref => undef,
        sub_sow_refs   => [],
        epic_refs      => [],
        links          => [],
      } if $type eq 'sow';
    return {
        sow_ref         => undef,
        parent_epic_ref => undef,
        sub_epic_refs   => [],
        ticket_refs     => [],
        links           => [],
      } if $type eq 'epic';
    return {
        epic_ref          => undef,
        parent_ticket_ref => undef,
        sub_ticket_refs   => [],
        links             => [],
    };
}

sub _markdown {
    my ( $self, $data ) = @_;
    if ( ref($data) eq 'HASH' && exists $data->{ref} ) {
        my $description = $data->{description} ne '' ? $data->{description} : '_No description._';
        return "# $data->{ref}: $data->{title}\n\n$description\n\n"
          . "- Type: `$data->{type}`\n"
          . "- Created: $data->{created_at}\n"
          . "- Last Updated: $data->{last_updated}\n";
    }
    return "# Tira Result\n\n```json\n" . JSON::PP->new->canonical->pretty->encode($data) . "```\n";
}

sub _with_project_lock {
    my ( $self, $root, $code ) = @_;
    my $lock_path = File::Spec->catfile( $root, '.tira', '.lock' );
    open my $lock, '>>', $lock_path or die "Cannot open project lock '$lock_path': $!\n";
    flock( $lock, LOCK_EX ) or die "Cannot lock Tira project '$root': $!\n";
    my ( $result, $error );
    eval { $result = $code->(); 1 } or $error = $@ || 'Unknown locked operation failure';
    close $lock or die "Cannot close project lock '$lock_path': $!\n";
    die $error if defined $error;
    return $result;
}

sub _write_yaml {
    my ( $self, $path, $data ) = @_;
    $self->_atomic_write( $path, $self->{yaml}->dump_string($data) );
}

sub _validated_counter {
    my ( $self, $config, $path ) = @_;
    my $prefix = $config->{prefix};
    die "Invalid prefix in '$path'\n" if !defined $prefix || $prefix !~ /\A([A-Z][A-Z0-9-]{0,31})\z/;
    $prefix = $1;
    my $digits = $config->{digits};
    die "Invalid digits in '$path'\n" if !defined $digits || $digits !~ /\A(\d+)\z/ || $1 < 1 || $1 > 12;
    $digits = 0 + $1;
    my $number = $config->{next_number};
    die "Invalid next_number in '$path'\n" if !defined $number || $number !~ /\A(\d+)\z/ || $1 < 1;
    $number = 0 + $1;
    return ( $prefix, $digits, $number );
}

sub _canonical_path {
    my ( $self, $candidate, $label ) = @_;
    my $resolved = realpath($candidate);
    die "Cannot resolve $label\n" if !defined $resolved;
    die "Unsafe control character in $label\n" if $resolved =~ /[\x00-\x1f\x7f]/;
    $resolved =~ /\A(.+)\z/ or die "Cannot validate $label\n";
    return $1;
}

sub _write_json {
    my ( $self, $path, $data ) = @_;
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    $self->_atomic_write( $path, $json );
}

sub _atomic_write {
    my ( $self, $path, $content ) = @_;
    my $dir = dirname($path);
    my ( $fh, $temporary ) = tempfile( '.tira-write-XXXXXX', DIR => $dir, UNLINK => 0 );
    $temporary = $self->_canonical_path( $temporary, "temporary file for '$path'" );
    binmode $fh, ':raw';
    print {$fh} $content or die "Cannot write temporary file for '$path': $!\n";
    close $fh or die "Cannot close temporary file for '$path': $!\n";
    rename $temporary, $path or do {
        my $error = $!;
        unlink $temporary;
        die "Cannot replace '$path': $error\n";
    };
    return 1;
}

1;

__END__

=head1 NAME

Tira - Filesystem-native Kanban project management engine

=head1 SYNOPSIS

  my $tira = Tira->new;
  $tira->create_project(dir => 'demo', name => 'Demo');
  my $ticket = $tira->create_record(type => 'ticket', title => 'Ship it');
  print $tira->format_output($ticket);

=head1 DESCRIPTION

Tira stores project configuration beneath C<.tira>, represents board columns as
folders, and stores SOW, epic, and ticket records as JSON files. This module owns
safe project discovery, atomic persistence, monotonic reference allocation, and
the shared TOON, JSON, and Markdown output contract.

=head1 METHODS

=head2 new

Creates an engine. Tests may supply a C<clock> callback.

=head2 create_project

Creates the canonical project and board layout.

=head2 discover_project

Finds C<.tira/project.yml> by explicit root or upward directory traversal.

=head2 create_record

Creates one free-ranging SOW, epic, or ticket in its Backlog column.

=head2 format_output

Encodes data as TOON by default, pretty JSON, or Markdown.

=cut
