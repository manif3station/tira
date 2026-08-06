package Tira;

use strict;
use warnings;

use Cwd qw(abs_path realpath);
use Data::TOON;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode_utf8 FB_QUIET);
use Fcntl qw(:flock);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP ();
use POSIX qw(strftime);
use YAML::PP;

our $VERSION = '0.10';

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
    $dir = $self->_safe_path_input( $dir, 'project directory' );

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
            schema_version => 2,
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
    my $type = $self->_valid_type( $args{type} );
    my $title = $args{title};
    die "Record title is required\n" if !defined $title || $title eq '';
    my $root = $self->discover_project(
        defined $args{project} ? ( project => $args{project} ) : ( start => $args{start} // '.' ),
    );
    $self->_require_active_person( project => $root, person => $args{assignee} )
      if defined $args{assignee} && $args{assignee} ne '';
    $self->_require_active_person( project => $root, person => $args{reporter} )
      if defined $args{reporter} && $args{reporter} ne '';
    my $labels = $self->_unique_casefold( $args{labels} // [] );
    my $affects_versions = $self->_unique_casefold( $args{affects_versions} // [] );
    my $priority = $self->_valid_priority( $args{priority} );
    my $due_date = $self->_valid_datetime( $args{due_date}, 'Due date' );
    my $start_date = $self->_valid_datetime( $args{start_date}, 'Start date' );
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
                    key_details          => $args{key_details} // [],
                    problem_or_feature   => $args{problem_or_feature} // '',
                    solution_needed      => $args{solution_needed} // '',
                    deliverables         => $args{deliverables} // [],
                    scope                => { included => $args{scope_in} // [], excluded => $args{scope_out} // [] },
                    source               => $args{source} // '',
                    acceptance_criteria  => $args{acceptance} // [],
                    test_steps           => $args{test_steps} // [],
                    bdd                  => $args{bdd} // [],
                    atdd                 => $args{atdd} // [],
                gate_passing_log     => [],
                evidence             => [],
                attachments          => [],
                checklist            => [],
                subtasks             => [],
                linkage              => $self->_empty_linkage($type),
                assignee             => $args{assignee},
                reporter             => $args{reporter},
                labels               => $labels,
                due_date             => $due_date,
                start_date           => $start_date,
                sdlc_gate            => $args{sdlc_gate},
                lifecycle            => $args{lifecycle},
                priority             => $priority,
                fix_version          => $args{fix_version},
                affects_versions     => $affects_versions,
                parent               => undef,
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

sub project_show {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $data = $self->{yaml}->load_file( File::Spec->catfile( $root, '.tira', 'project.yml' ) );
    for my $person ( @{ $data->{people} } ) {
        $person->{active} = JSON::PP::true if !exists $person->{active};
    }
    return $data;
}

sub project_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
        my $data = $self->{yaml}->load_file($path);
        $data->{name} = $args{name} if defined $args{name};
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $data;
    } );
}

sub person_list {
    my ( $self, %args ) = @_;
    return $self->project_show(%args)->{people};
}

sub person_add {
    my ( $self, %args ) = @_;
    die "Person id is required\n" if !defined $args{id} || $args{id} eq '';
    die "Person name is required\n" if !defined $args{name} || $args{name} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        die "Person '$args{id}' already exists\n" if grep { $_->{id} eq $args{id} } @{ $data->{people} };
        my $person = { id => $args{id}, name => $args{name}, email => $args{email} // '', active => JSON::PP::true };
        push @{ $data->{people} }, $person;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

sub person_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($person) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if !$person;
        $person->{name} = $args{name} if defined $args{name};
        $person->{email} = $args{email} if defined $args{email};
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

sub person_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        for my $record ( @{ $self->record_list( project => $root ) } ) {
            my @references = ( $record->{assignee}, $record->{reporter} );
            push @references, map { $_->{author} } @{ $record->{comments} // [] };
            push @references, map { $_->{author} } @{ $record->{evidence} // [] };
            push @references, map { $_->{author} } @{ $record->{gate_passing_log} // [] };
            die "Person '$args{id}' has a historical reference\n"
              if grep { defined $_ && $_ eq ( $args{id} // '' ) } @references;
        }
        my ( $path, $data ) = $self->_project_data($root);
        my @kept = grep { $_->{id} ne ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if @kept == @{ $data->{people} };
        $data->{people} = \@kept;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return { removed => $args{id} };
    } );
}

sub person_activate {
    my ( $self, %args ) = @_;
    return $self->_set_person_active( %args, active => JSON::PP::true );
}

sub person_deactivate {
    my ( $self, %args ) = @_;
    return $self->_set_person_active( %args, active => JSON::PP::false );
}

sub link_type_list {
    my ( $self, %args ) = @_;
    return $self->project_show(%args)->{link_types};
}

sub link_type_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        die "Link type names are required\n" if !$args{outward} || !$args{inward};
        die "Link type '$args{outward}' already exists\n"
          if grep { $_->{outward} eq $args{outward} || $_->{inward} eq $args{outward} } @{ $data->{link_types} };
        my $link = { outward => $args{outward}, inward => $args{inward}, protected => JSON::PP::false };
        push @{ $data->{link_types} }, $link;
        $self->_write_yaml( $path, $data );
        return $link;
    } );
}

sub link_type_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($match) = grep { $_->{outward} eq ( $args{outward} // '' ) } @{ $data->{link_types} };
        die "Link type '$args{outward}' not found\n" if !$match;
        die "Link type '$args{outward}' is protected\n" if $match->{protected};
        for my $record ( @{ $self->record_list( project => $root ) } ) {
            die "Link type '$args{outward}' is still in use\n"
              if grep { $_->{type} eq $match->{outward} || $_->{type} eq $match->{inward} } @{ $record->{linkage}{links} };
        }
        $data->{link_types} = [ grep { $_->{outward} ne $args{outward} } @{ $data->{link_types} } ];
        $self->_write_yaml( $path, $data );
        return { removed => $args{outward} };
    } );
}

sub column_list {
    my ( $self, %args ) = @_;
    my ( undef, $config ) = $self->_board_data(%args);
    return $config->{columns};
}

sub board_show {
    my ( $self, %args ) = @_;
    my ( undef, $config ) = $self->_board_data(%args);
    return $config;
}

sub column_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        die "Column '$args{name}' already exists\n" if grep { $_->{name} eq $args{name} } @{ $config->{columns} };
        die "Use only one of --after or --before\n" if defined $args{after} && defined $args{before};
        my $column = { name => $args{name}, label => $args{label} // $args{name}, protected => JSON::PP::false };
        my $position = @{ $config->{columns} } - 1;
        for my $i ( 0 .. $#{ $config->{columns} } ) {
            $position = $i + 1 if defined $args{after} && $config->{columns}[$i]{name} eq $args{after};
            $position = $i if defined $args{before} && $config->{columns}[$i]{name} eq $args{before};
        }
        splice @{ $config->{columns} }, $position, 0, $column;
        my $directory = File::Spec->catdir( dirname($path), $args{name} );
        make_path($directory);
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column configuration failure';
            rmdir $directory;
            die $error;
        };
        return $column;
    } );
}

sub column_rename {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    $args{new_name} = $self->_valid_slug( $args{new_name} );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '$args{name}' not found\n" if !$column;
        die "Column '$args{name}' is protected\n" if $column->{protected};
        die "Column '$args{new_name}' already exists\n" if grep { $_->{name} eq $args{new_name} } @{ $config->{columns} };
        my $board = dirname($path);
        my $old_directory = File::Spec->catdir( $board, $args{name} );
        my $new_directory = File::Spec->catdir( $board, $args{new_name} );
        rename $old_directory, $new_directory
          or die "Cannot rename column '$args{name}': $!\n";
        $column->{name} = $args{new_name};
        $column->{label} = $args{label} if defined $args{label};
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column configuration failure';
            rename $new_directory, $old_directory or die "$error; rollback rename failed: $!\n";
            die $error;
        };
        return $column;
    } );
}

sub column_reorder {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    $args{after} = $self->_valid_slug( $args{after} ) if defined $args{after};
    $args{before} = $self->_valid_slug( $args{before} ) if defined $args{before};
    return $self->_with_project_lock( $root, sub {
        die "Use exactly one of --after or --before\n" if ( defined $args{after} ? 1 : 0 ) + ( defined $args{before} ? 1 : 0 ) != 1;
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '$args{name}' not found\n" if !$column;
        die "Column '$args{name}' is protected\n" if $column->{protected};
        my @columns = grep { $_ != $column } @{ $config->{columns} };
        my $target = $args{after} // $args{before};
        my ($index) = grep { $columns[$_]{name} eq $target } 0 .. $#columns;
        die "Column '$target' not found\n" if !defined $index;
        $index++ if defined $args{after};
        splice @columns, $index, 0, $column;
        $config->{columns} = \@columns;
        $self->_write_yaml( $path, $config );
        return $column;
    } );
}

sub column_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '$args{name}' not found\n" if !$column;
        die "Column '$args{name}' is protected\n" if $column->{protected};
        my $board = dirname($path);
        my $source = File::Spec->catdir( $board, $args{name} );
        my $discard = File::Spec->catdir( $board, 'discard' );
        opendir my $dh, $source or die "Cannot read column '$args{name}': $!\n";
        my @names = map { /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12}\.json)\z/ ? $1 : () }
          grep { -f File::Spec->catfile( $source, $_ ) } readdir $dh;
        for my $name (@names) {
            my $file = File::Spec->catfile( $source, $name );
            rename $file, File::Spec->catfile( $discard, $name ) or die "Cannot discard '$file': $!\n";
        }
        closedir $dh;
        $config->{columns} = [ grep { $_->{name} ne $args{name} } @{ $config->{columns} } ];
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column configuration failure';
            rename File::Spec->catfile( $discard, $_ ), File::Spec->catfile( $source, $_ ) for @names;
            die $error;
        };
        rmdir $source or die "Cannot remove column '$args{name}': $!\n";
        return { removed => $args{name}, destination => 'discard' };
    } );
}

sub board_refs {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        $config->{prefix} = $args{prefix} if defined $args{prefix};
        $config->{digits} = $args{digits} if defined $args{digits};
        $self->_validated_counter( $config, $path );
        $self->_write_yaml( $path, $config );
        return $config;
    } );
}

sub record_show {
    my ( $self, %args ) = @_;
    my ( $path, $record, $column ) = $self->_record_data(%args);
    return { %{$record}, column => $column };
}

sub record_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my @records;
    for my $candidate ( defined $args{type} ? ( $args{type} ) : qw(sow epic ticket) ) {
        my $type = $self->_valid_type($candidate);
        my $board = File::Spec->catdir( $root, '.tira', $type );
        next if !-d $board;
        find( { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name || basename( $File::Find::name ) !~ /\.json\z/;
            my $path = $self->_canonical_path( $File::Find::name, 'record file' );
            my $record = $self->_read_json($path);
            my $column = basename( dirname($path) );
            return if defined $args{column} && $column ne $args{column};
            return if defined $args{assignee} && ( $record->{assignee} // '' ) ne $args{assignee};
            my $parent = $record->{parent} // '';
            return if defined $args{parent} && $parent ne $args{parent};
            if ( defined $args{text} ) {
                my $haystack = join ' ', $record->{ref}, $record->{title}, $record->{description};
                return if index( lc $haystack, lc $args{text} ) < 0;
            }
            push @records, { %{$record}, column => $column };
        } }, $board );
    }
    return [ sort { $a->{ref} cmp $b->{ref} } @records ];
}

sub export_records {
    my ( $self, %args ) = @_;
    my $records = $self->record_list(%args);
    return { records => $records, count => scalar @{$records} };
}

sub record_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $record, $column ) = $self->_record_data( project => $root, ref => $args{ref} );
        for my $field (qw(title description problem_or_feature solution_needed source sdlc_gate lifecycle fix_version)) {
            $record->{$field} = $args{$field} if defined $args{$field};
        }
        for my $field (qw(sdlc_gate lifecycle fix_version)) {
            $record->{$field} = undef if defined $args{$field} && $args{$field} eq '';
        }
        for my $field (qw(assignee reporter)) {
            next if !defined $args{$field};
            $self->_require_active_person( project => $root, person => $args{$field} ) if $args{$field} ne '';
            $record->{$field} = $args{$field} eq '' ? undef : $args{$field};
        }
        $record->{priority} = $self->_valid_priority( $args{priority} ) if defined $args{priority};
        $record->{due_date} = $self->_valid_datetime( $args{due_date}, 'Due date' ) if defined $args{due_date};
        $record->{start_date} = $self->_valid_datetime( $args{start_date}, 'Start date' ) if defined $args{start_date};
        if ( defined $args{labels} ) {
            $record->{labels} = $self->_unique_casefold( [ @{ $record->{labels} // [] }, @{ $args{labels} } ] );
        }
        $record->{labels} = $self->_unique_casefold( $args{labels_replace} ) if defined $args{labels_replace};
        if ( defined $args{affects_versions} ) {
            $record->{affects_versions} = $self->_unique_casefold(
                [ @{ $record->{affects_versions} // [] }, @{ $args{affects_versions} } ]
            );
        }
        $record->{affects_versions} = $self->_unique_casefold( $args{affects_versions_replace} )
          if defined $args{affects_versions_replace};
        my %accumulating = (
            key_details => 'key_details', deliverables => 'deliverables', acceptance => 'acceptance_criteria',
            test_steps => 'test_steps', bdd => 'bdd', atdd => 'atdd',
        );
        for my $argument ( keys %accumulating ) {
            next if !defined $args{$argument};
            push @{ $record->{ $accumulating{$argument} } }, @{ $args{$argument} };
        }
        for my $argument ( keys %accumulating ) {
            my $replacement = "${argument}_replace";
            $record->{ $accumulating{$argument} } = $args{$replacement} if defined $args{$replacement};
        }
        my %arrays = ( attachments => 'attachments', evidence => 'evidence', gate_passing_log => 'gate_passing_log' );
        for my $argument ( keys %arrays ) {
            $record->{ $arrays{$argument} } = $args{$argument} if defined $args{$argument};
        }
        push @{ $record->{scope}{included} }, @{ $args{scope_in} } if defined $args{scope_in};
        push @{ $record->{scope}{excluded} }, @{ $args{scope_out} } if defined $args{scope_out};
        $record->{scope} = $args{scope} if defined $args{scope};
        $record->{last_updated} = $self->{clock}->();
        $self->_write_json( $path, $record );
        return { %{$record}, column => $column };
    } );
}

sub record_move {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $record ) = $self->_record_data( project => $root, ref => $args{ref} );
        my $type = $record->{type};
        die "Invalid record type in '$args{ref}'\n" if $type !~ /\A(sow|epic|ticket)\z/;
        $type = $1;
        my $column = $self->_valid_slug( $args{column} );
        my ( undef, $config ) = $self->_board_data( project => $root, type => $type );
        die "Column '$column' not found\n" if !grep { $_->{name} eq $column } @{ $config->{columns} };
        my $destination = File::Spec->catfile( $root, '.tira', $type, $column, basename($path) );
        rename $path, $destination or die "Cannot move '$args{ref}': $!\n";
        return { %{$record}, column => $column };
    } );
}

sub record_discard {
    my ( $self, %args ) = @_;
    return $self->record_move( %args, column => 'discard' );
}

sub record_restore {
    my ( $self, %args ) = @_;
    return $self->record_move( %args, column => $args{column} // 'backlog' );
}

sub project_validate {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    if ( $args{repair} ) {
        $self->column_sync( project => $root, type => $_, apply => 1 ) for qw(sow epic ticket);
    }
    my @issues;
    for my $type (qw(sow epic ticket)) {
        my ( undef, $config ) = $self->_board_data( project => $root, type => $type );
        my %configured = map { $_->{name} => 1 } @{ $config->{columns} };
        my $board = File::Spec->catdir( $root, '.tira', $type );
        opendir my $dh, $board or die "Cannot read board '$type': $!\n";
        my %actual = map { $_ => 1 } grep { -d File::Spec->catdir( $board, $_ ) && !/^\./ } readdir $dh;
        closedir $dh;
        push @issues, map { "$type: missing directory $_" } grep { !$actual{$_} } sort keys %configured;
        push @issues, map { "$type: unconfigured directory $_" } grep { !$configured{$_} } sort keys %actual;
    }
    return { valid => @issues ? JSON::PP::false : JSON::PP::true, issues => \@issues };
}

sub column_sync {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
    my $board = dirname($path);
    opendir my $dh, $board or die "Cannot read board '$args{type}': $!\n";
    my @actual = sort grep { -d File::Spec->catdir( $board, $_ ) && !/^\./ } readdir $dh;
    closedir $dh;
    my %actual = map { $_ => 1 } @actual;
    my %configured = map { $_->{name} => $_ } @{ $config->{columns} };
    my @missing = grep { !$actual{$_} } sort keys %configured;
    my @unconfigured = grep { !$configured{$_} } @actual;
    if ( $args{apply} ) {
        make_path( File::Spec->catdir( $board, $_ ) ) for grep { $configured{$_}{protected} } @missing;
        my @columns = grep { $actual{ $_->{name} } || $_->{protected} } @{ $config->{columns} };
        my $discard = pop @columns;
        push @columns, map { { name => $_, label => $_, protected => JSON::PP::false } } @unconfigured;
        push @columns, $discard;
        $config->{columns} = \@columns;
        $self->_write_yaml( $path, $config );
    }
    return { missing => \@missing, unconfigured => \@unconfigured, applied => $args{apply} ? JSON::PP::true : JSON::PP::false };
}

sub hierarchy_link {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        my ( $up, $down );
        if ( $parent->{type} eq 'sow' && $child->{type} eq 'epic' ) {
            ( $up, $down ) = ( 'sow_ref', 'epic_refs' );
        }
        elsif ( $parent->{type} eq 'epic' && $child->{type} eq 'ticket' ) {
            ( $up, $down ) = ( 'epic_ref', 'ticket_refs' );
        }
        else {
            die "Hierarchy requires SOW-to-epic or epic-to-ticket\n";
        }
        my $old_parent_ref = $child->{linkage}{$up};
        my @updates;
        if ( defined $old_parent_ref && $old_parent_ref ne $parent->{ref} ) {
            my ( $old_path, $old_parent ) = $self->_record_data( project => $root, ref => $old_parent_ref );
            $old_parent->{linkage}{$down} = [ grep { $_ ne $child->{ref} } @{ $old_parent->{linkage}{$down} } ];
            $old_parent->{last_updated} = $self->{clock}->();
            push @updates, [ $old_path, $old_parent ];
        }
        $child->{linkage}{$up} = $parent->{ref};
        $child->{parent} = $child->{linkage}{"parent_$child->{type}_ref"} // $parent->{ref};
        push @{ $parent->{linkage}{$down} }, $child->{ref}
          if !grep { $_ eq $child->{ref} } @{ $parent->{linkage}{$down} };
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        push @updates, [ $parent_path, $parent ], [ $child_path, $child ];
        $self->_write_json_transaction(\@updates);
        return { parent => $parent->{ref}, child => $child->{ref} };
    } );
}

sub hierarchy_unlink {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        my ( $up, $down ) = $parent->{type} eq 'sow' && $child->{type} eq 'epic'
          ? ( 'sow_ref', 'epic_refs' )
          : $parent->{type} eq 'epic' && $child->{type} eq 'ticket'
          ? ( 'epic_ref', 'ticket_refs' )
          : die "Hierarchy requires SOW-to-epic or epic-to-ticket\n";
        die "Records are not linked in that hierarchy\n" if ( $child->{linkage}{$up} // '' ) ne $parent->{ref};
        $child->{linkage}{$up} = undef;
        $child->{parent} = $child->{linkage}{"parent_$child->{type}_ref"};
        $parent->{linkage}{$down} = [ grep { $_ ne $child->{ref} } @{ $parent->{linkage}{$down} } ];
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        $self->_write_json_transaction( [ [ $parent_path, $parent ], [ $child_path, $child ] ] );
        return { parent => $parent->{ref}, child => $child->{ref}, unlinked => JSON::PP::true };
    } );
}

sub hierarchy_show {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my %seen;
    my $build;
    $build = sub {
        my ($ref) = @_;
        die "Hierarchy cycle detected at '$ref'\n" if $seen{$ref}++;
        my $record = $self->record_show( project => $root, ref => $ref );
        my $children = $record->{type} eq 'sow' ? $record->{linkage}{epic_refs}
          : $record->{type} eq 'epic' ? $record->{linkage}{ticket_refs} : [];
        my $node = { ref => $ref, type => $record->{type}, title => $record->{title}, children => [] };
        if ( $args{recursive} ) {
            push @{ $node->{children} }, $build->($_) for @{$children};
        }
        else {
            $node->{children} = [ map { { ref => $_ } } @{$children} ];
        }
        $seen{$ref}--;
        return $node;
    };
    return $build->( $args{ref} );
}

sub subitem_link {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        die "Subitems must have the same type\n" if $parent->{type} ne $child->{type};
        die "Subitem cycle detected\n" if $self->_is_subitem_descendant( $root, $child->{ref}, $parent->{ref} );
        my $type = $parent->{type};
        my $up = "parent_${type}_ref";
        my $down = "sub_${type}_refs";
        die "Child already has a different subitem parent\n"
          if defined $child->{linkage}{$up} && $child->{linkage}{$up} ne $parent->{ref};
        $child->{linkage}{$up} = $parent->{ref};
        $child->{parent} = $parent->{ref};
        push @{ $parent->{linkage}{$down} }, $child->{ref}
          if !grep { $_ eq $child->{ref} } @{ $parent->{linkage}{$down} };
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        $self->_write_json_transaction( [ [ $parent_path, $parent ], [ $child_path, $child ] ] );
        return { parent => $parent->{ref}, child => $child->{ref} };
    } );
}

sub subitem_unlink {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        die "Subitems must have the same type\n" if $parent->{type} ne $child->{type};
        my $type = $parent->{type};
        my $up = "parent_${type}_ref";
        my $down = "sub_${type}_refs";
        die "Records are not linked as subitems\n" if ( $child->{linkage}{$up} // '' ) ne $parent->{ref};
        $child->{linkage}{$up} = undef;
        $child->{parent} = $child->{linkage}{sow_ref} // $child->{linkage}{epic_ref};
        $parent->{linkage}{$down} = [ grep { $_ ne $child->{ref} } @{ $parent->{linkage}{$down} } ];
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        $self->_write_json_transaction( [ [ $parent_path, $parent ], [ $child_path, $child ] ] );
        return { parent => $parent->{ref}, child => $child->{ref}, unlinked => JSON::PP::true };
    } );
}

sub link_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $from_path, $from ) = $self->_record_data( project => $root, ref => $args{from} );
        my ( $to_path, $to ) = $self->_record_data( project => $root, ref => $args{to} );
        my $reciprocal = $self->_reciprocal_type( $root, $args{type} );
        push @{ $from->{linkage}{links} }, { type => $args{type}, ref => $to->{ref} }
          if !grep { $_->{type} eq $args{type} && $_->{ref} eq $to->{ref} } @{ $from->{linkage}{links} };
        push @{ $to->{linkage}{links} }, { type => $reciprocal, ref => $from->{ref} }
          if !grep { $_->{type} eq $reciprocal && $_->{ref} eq $from->{ref} } @{ $to->{linkage}{links} };
        $self->_write_json_transaction( [ [ $from_path, $from ], [ $to_path, $to ] ] );
        return { from => $from->{ref}, type => $args{type}, to => $to->{ref}, reciprocal => $reciprocal };
    } );
}

sub link_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $from_path, $from ) = $self->_record_data( project => $root, ref => $args{from} );
        my ( $to_path, $to ) = $self->_record_data( project => $root, ref => $args{to} );
        my $reciprocal = $self->_reciprocal_type( $root, $args{type} );
        $from->{linkage}{links} = [ grep { !( $_->{type} eq $args{type} && $_->{ref} eq $to->{ref} ) } @{ $from->{linkage}{links} } ];
        $to->{linkage}{links} = [ grep { !( $_->{type} eq $reciprocal && $_->{ref} eq $from->{ref} ) } @{ $to->{linkage}{links} } ];
        $self->_write_json_transaction( [ [ $from_path, $from ], [ $to_path, $to ] ] );
        return { removed => JSON::PP::true };
    } );
}

sub link_list {
    my ( $self, %args ) = @_;
    my $links = $self->record_show(%args)->{linkage}{links};
    return [ grep { !defined $args{type} || $_->{type} eq $args{type} } @{$links} ];
}

sub assignment_list {
    my ( $self, %args ) = @_;
    my $person = $self->record_show(%args)->{assignee};
    return defined $person ? [$person] : [];
}

sub assignment_add {
    my ( $self, %args ) = @_;
    return $self->assignment_set( %args, people => [ $args{person} ] );
}

sub assignment_remove {
    my ( $self, %args ) = @_;
    my $current = $self->record_show(%args)->{assignee};
    return $self->record_show(%args) if !defined $current || $current ne ( $args{person} // '' );
    return $self->assignment_set( %args, people => [] );
}

sub assignment_set {
    my ( $self, %args ) = @_;
    my $people = $args{people} // [];
    die "A record accepts only one assignee\n" if @{$people} > 1;
    return $self->record_update( %args, assignee => @{$people} ? $people->[0] : '' );
}

sub comment_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{comments};
}

sub comment_add {
    my ( $self, %args ) = @_;
    $self->_require_person( %args, person => $args{author} );
    my $record = $self->record_show(%args);
    my $number = 1;
    for my $existing ( @{ $record->{comments} } ) {
        $number = $1 + 1 if $existing->{id} =~ /\ACMT-(\d+)\z/ && $1 >= $number;
    }
    my $now = $self->{clock}->();
    my $comment = {
        id => sprintf( 'CMT-%03d', $number ), author => $args{author}, format => $args{format} // 'markdown',
        body => $args{text} // '', attachments => [], created_at => $now, last_updated => $now,
    };
    push @{ $record->{comments} }, $comment;
    $self->_replace_record( %args, record => $record );
    return $comment;
}

sub comment_update {
    my ( $self, %args ) = @_;
    my $record = $self->record_show(%args);
    my ($comment) = grep { $_->{id} eq ( $args{comment} // '' ) } @{ $record->{comments} };
    die "Comment '$args{comment}' not found\n" if !$comment;
    $comment->{body} = $args{text} if defined $args{text};
    $comment->{format} = $args{format} if defined $args{format};
    $comment->{last_updated} = $self->{clock}->();
    $self->_replace_record( %args, record => $record );
    return $comment;
}

sub comment_attach {
    my ( $self, %args ) = @_;
    return $self->attachment_add(%args);
}

sub attachment_add {
    my ( $self, %args ) = @_;
    my $file = $self->_canonical_path( $args{file}, "attachment '$args{file}'" );
    open my $fh, '<:raw', $file or die "Cannot read attachment '$file': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    my $sha = sha256_hex($content);
    $sha =~ /\A([0-9a-f]{64})\z/ or die "Cannot validate attachment SHA\n";
    $sha = $1;
    my $name = basename($file);
    my $extension = $name =~ /\.([A-Za-z0-9]+)\z/ ? lc $1 : 'bin';
    my $root = $self->discover_project(%args);
    my $stored = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.$extension" );
    $self->_atomic_write( $stored, $content ) if !-f $stored;
    my $reference = { sha => $sha, extension => $extension, original_filename => $name };
    my $record = $self->record_show( project => $root, ref => $args{ref} );
    my $attachments;
    if ( defined $args{comment} ) {
        my ($comment) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
        die "Comment '$args{comment}' not found\n" if !$comment;
        $attachments = $comment->{attachments};
    }
    else {
        $attachments = $record->{attachments};
    }
    my ($retained) = grep { $_->{sha} eq $sha && $_->{extension} eq $extension } @{$attachments};
    my $deduped = defined $retained;
    if ( !$deduped ) {
        push @{$attachments}, $reference;
        $retained = $reference;
    }
    $self->_replace_record( project => $root, ref => $args{ref}, record => $record );
    return {
        %{$retained}, supplied_filename => $name,
        deduped => $deduped ? JSON::PP::true : JSON::PP::false,
    };
}

sub attachment_get {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_attachment_path( $root, %args );
    if ( defined $path && -f $path ) {
        open my $fh, '<:raw', $path or die "Cannot read attachment: $!\n";
        my $content = do { local $/; <$fh> };
        close $fh;
        return { content => $content, deleted => 0 };
    }
    my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
    if ( -f $log_path ) {
        my $entries = $self->{yaml}->load_file($log_path) || [];
        my ($entry) = reverse grep { $_->{sha} eq ( $args{sha} // '' ) && ( !defined $args{extension} || $_->{extension} eq $args{extension} ) } @{$entries};
        return { content => "Deleted at $entry->{deleted_at}\n", deleted => 1, deleted_at => $entry->{deleted_at} } if $entry;
    }
    die "Attachment '$args{sha}' not found\n";
}

sub attachment_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_attachment_path( $root, %args );
    die "Attachment '$args{sha}' not found\n" if !defined $path || !-f $path;
    my $extension = $args{extension} // ( basename($path) =~ /\.([^.]+)\z/ ? $1 : 'bin' );
    unlink $path or die "Cannot remove attachment: $!\n";
    my $entry = { sha => $args{sha}, extension => $extension, deleted_at => $self->{clock}->() };
    my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
    my $entries = -f $log_path ? ( $self->{yaml}->load_file($log_path) || [] ) : [];
    push @{$entries}, $entry;
    $self->_write_yaml( $log_path, $entries );
    return $entry;
}

sub attachment_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{attachments} if defined $args{ref};
    my $root = $self->discover_project(%args);
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @items = map { my ( $sha, $ext ) = /\A([0-9a-f]{64})\.([^.]+)\z/; { sha => $sha, extension => $ext } }
      grep { /\A[0-9a-f]{64}\.[^.]+\z/ } readdir $dh;
    closedir $dh;
    if ( $args{include_deleted} ) {
        my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
        if ( -f $log_path ) {
            push @items, map { { %{$_}, deleted => JSON::PP::true } } @{ $self->{yaml}->load_file($log_path) || [] };
        }
    }
    return \@items;
}

sub record_clone {
    my ( $self, %args ) = @_;
    my $source = $self->record_show(%args);
    my $clone = $self->create_record( project => $args{project}, type => $source->{type}, title => $args{title}, description => $source->{description} );
    my %copy = %{$source};
    delete @copy{qw(ref column type title created_at last_updated linkage comments assignee parent)};
    $clone = $self->record_update( project => $args{project}, ref => $clone->{ref}, %copy );
    $self->link_add( project => $args{project}, from => $source->{ref}, type => 'clones', to => $clone->{ref} );
    return $self->record_show( project => $args{project}, ref => $clone->{ref} );
}

sub evidence_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{evidence};
}

sub evidence_add {
    my ( $self, %args ) = @_;
    $self->_require_person( %args, person => $args{author} ) if defined $args{author};
    my $record = $self->record_show(%args);
    die "Evidence summary is required\n" if !defined $args{summary} || $args{summary} eq '';
    my $attachment = defined $args{file} ? $self->attachment_add(%args) : undef;
    $record = $self->record_show(%args) if $attachment;
    my $stored_attachment = $attachment
      ? { map { $_ => $attachment->{$_} } qw(sha extension original_filename) }
      : undef;
    my $entry = {
        id => sprintf( 'EVD-%03d', @{ $record->{evidence} } + 1 ),
        summary => $args{summary}, uri => $args{uri} // '', author => $args{author},
        attachment => $stored_attachment, annotations => [], created_at => $self->{clock}->(),
    };
    push @{ $record->{evidence} }, $entry;
    $self->_replace_record( %args, record => $record );
    return $entry;
}

sub evidence_annotate {
    my ( $self, %args ) = @_;
    return $self->_annotate_log( %args, field => 'evidence', label => 'Evidence' );
}

sub gate_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{gate_passing_log};
}

sub gate_add {
    my ( $self, %args ) = @_;
    die "Invalid gate result\n" if ( $args{result} // '' ) !~ /\A(?:pass|fail|blocked)\z/;
    $self->_require_person( %args, person => $args{author} ) if defined $args{author};
    my $record = $self->record_show(%args);
    my $entry = {
        id => sprintf( 'GATE-%03d', @{ $record->{gate_passing_log} } + 1 ),
        gate => $args{gate}, result => $args{result}, details => $args{details},
        author => $args{author}, annotations => [], created_at => $self->{clock}->(),
    };
    push @{ $record->{gate_passing_log} }, $entry;
    $self->_replace_record( %args, record => $record );
    return $entry;
}

sub gate_annotate {
    my ( $self, %args ) = @_;
    return $self->_annotate_log( %args, field => 'gate_passing_log', label => 'Gate' );
}

sub checklist_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{checklist};
}

sub checklist_add {
    my ( $self, %args ) = @_;
    die "Checklist item is required\n" if !defined $args{item} || $args{item} eq '';
    die "Checklist status is required\n" if !defined $args{status} || $args{status} eq '';
    my $record = $self->record_show(%args);
    my $number = @{ $record->{checklist} } + 1;
    my $now = $self->{clock}->();
    my $entry = {
        id => sprintf( 'CHK-%03d', $number ), item => $args{item}, status => $args{status},
        created_at => $now, last_updated => $now,
    };
    push @{ $record->{checklist} }, $entry;
    $self->_replace_record( %args, record => $record );
    return $entry;
}

sub checklist_update {
    my ( $self, %args ) = @_;
    die "Checklist item or status is required\n" if !defined $args{item} && !defined $args{status};
    die "Checklist item is required\n" if defined $args{item} && $args{item} eq '';
    die "Checklist status is required\n" if defined $args{status} && $args{status} eq '';
    my $record = $self->record_show(%args);
    my ($entry) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $record->{checklist} };
    die "Checklist entry '$args{id}' not found\n" if !$entry;
    $entry->{item} = $args{item} if defined $args{item};
    $entry->{status} = $args{status} if defined $args{status};
    $entry->{last_updated} = $self->{clock}->();
    $self->_replace_record( %args, record => $record );
    return $entry;
}

sub search {
    my ( $self, %args ) = @_;
    my @fields = defined $args{fields} ? @{ $args{fields} }
      : defined $args{field} ? ( $args{field} ) : ();
    if (@fields) {
        my @hits;
        my %filters = %args;
        delete @filters{qw(text field fields)};
        for my $record ( @{ $self->record_list(%filters) } ) {
            for my $field (@fields) {
                next if !exists $record->{$field};
                push @hits, map {
                    { ref => $record->{ref}, type => $record->{type}, column => $record->{column}, %{$_} }
                } $self->_field_hits( $record->{$field}, $field, $args{text} );
            }
        }
        return { hits => \@hits, count => scalar @hits };
    }
    my $hits = $self->record_list(%args);
    return { hits => $hits, count => scalar @{$hits} };
}

sub _annotate_log {
    my ( $self, %args ) = @_;
    die "$args{label} annotation note is required\n" if !defined $args{note} || $args{note} eq '';
    $self->_require_person( %args, person => $args{author} ) if defined $args{author};
    my $record = $self->record_show(%args);
    my ($entry) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $record->{ $args{field} } };
    die "$args{label} entry '$args{id}' not found\n" if !$entry;
    my $annotation = { note => $args{note}, author => $args{author}, created_at => $self->{clock}->() };
    push @{ $entry->{annotations} }, $annotation;
    $self->_replace_record( %args, record => $record );
    return $annotation;
}

sub _field_hits {
    my ( $self, $value, $path, $text ) = @_;
    my @hits;
    if ( !ref($value) ) {
        push @hits, { field => $path, value => $value }
          if defined $value && index( lc $value, lc( $text // '' ) ) >= 0;
    }
    elsif ( ref($value) eq 'ARRAY' ) {
        for my $index ( 0 .. $#{$value} ) {
            push @hits, $self->_field_hits( $value->[$index], "$path.$index", $text );
        }
    }
    elsif ( ref($value) eq 'HASH' ) {
        for my $key ( sort keys %{$value} ) {
            push @hits, $self->_field_hits( $value->{$key}, "$path.$key", $text );
        }
    }
    return @hits;
}

sub _replace_value {
    my ( $self, $value, $regex, $replacement ) = @_;
    my $changed = 0;
    if ( !ref($value) && defined $value ) {
        my $copy = $value;
        $changed = ( $copy =~ s/$regex/$replacement/g );
        $_[1] = $copy if $changed;
    }
    elsif ( ref($value) eq 'ARRAY' ) {
        $changed += $self->_replace_value( $value->[$_], $regex, $replacement ) for 0 .. $#{$value};
    }
    elsif ( ref($value) eq 'HASH' ) {
        $changed += $self->_replace_value( $value->{$_}, $regex, $replacement ) for keys %{$value};
    }
    return $changed;
}

sub bulk_import {
    my ( $self, %args ) = @_;
    my $changes = $args{changes};
    die "Import changes must be a JSON object\n" if ref($changes) ne 'HASH';
    my $root = $self->discover_project(%args);
    my %allowed = map { $_ => 1 } qw(
      title description key_details problem_or_feature solution_needed deliverables scope source
      acceptance_criteria test_steps bdd atdd assignee reporter labels due_date start_date
      sdlc_gate lifecycle priority fix_version affects_versions comments checklist
    );
    return $self->_with_project_lock( $root, sub {
        my ( @updates, @diffs );
        for my $ref ( sort keys %{$changes} ) {
            die "Import change for '$ref' must be a JSON object\n" if ref( $changes->{$ref} ) ne 'HASH';
            my ( $path, $record ) = $self->_record_data( project => $root, ref => $ref );
            for my $field ( sort keys %{ $changes->{$ref} } ) {
                die "Import field '$field' is not mutable\n" if !$allowed{$field};
                my $after = $changes->{$ref}{$field};
                my $before = $record->{$field};
                die "Import field '$field' has incompatible value type\n"
                  if defined $before && defined $after && ref($before) ne ref($after);
                next if JSON::PP->new->canonical->encode($before) eq JSON::PP->new->canonical->encode($after);
                push @diffs, { ref => $ref, field => $field, before => $before, after => $after };
                $record->{$field} = $after;
            }
            if ( grep { $_->{ref} eq $ref } @diffs ) {
                $record->{last_updated} = $self->{clock}->();
                push @updates, [ $path, $record ];
            }
        }
        $self->_write_json_transaction( \@updates ) if @updates && !$args{dry_run};
        my %changed = map { $_->{ref} => 1 } @diffs;
        return {
            dry_run => $args{dry_run} ? JSON::PP::true : JSON::PP::false,
            changed_records => scalar keys %changed, changes => \@diffs,
            requested_changes => $changes,
        };
    } );
}

sub replace_records {
    my ( $self, %args ) = @_;
    die "Replacement pattern is required\n" if !defined $args{pattern} || $args{pattern} eq '';
    die "Replacement text is required\n" if !defined $args{with};
    my $regex = eval { qr/$args{pattern}/ };
    die "Invalid replacement pattern: $@" if !$regex;
    my %mutable = map { $_ => 1 } qw(
      title description key_details problem_or_feature solution_needed deliverables scope source
      acceptance_criteria test_steps bdd atdd labels sdlc_gate lifecycle fix_version
      affects_versions comments checklist
    );
    my @selected = defined $args{fields} ? @{ $args{fields} }
      : defined $args{field} ? ( $args{field} ) : ();
    for my $field (@selected) {
        die "Replace field '$field' is not mutable\n" if !$mutable{$field};
    }
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( @updates, @diffs );
        for my $summary ( @{ $self->record_list( project => $root, defined $args{type} ? ( type => $args{type} ) : () ) } ) {
            my ( $path, $record ) = $self->_record_data( project => $root, ref => $summary->{ref} );
            my @fields = @selected ? @selected : sort keys %mutable;
            for my $field (@fields) {
                next if !exists $record->{$field};
                my $before = JSON::PP->new->canonical->decode( JSON::PP->new->canonical->encode( $record->{$field} ) );
                next if !$self->_replace_value( $record->{$field}, $regex, $args{with} );
                push @diffs, { ref => $record->{ref}, field => $field, before => $before, after => $record->{$field} };
            }
            if ( grep { $_->{ref} eq $record->{ref} } @diffs ) {
                $record->{last_updated} = $self->{clock}->();
                push @updates, [ $path, $record ];
            }
        }
        $self->_write_json_transaction( \@updates ) if @updates && !$args{dry_run};
        my %changed = map { $_->{ref} => 1 } @diffs;
        return { dry_run => $args{dry_run} ? JSON::PP::true : JSON::PP::false,
          changed_records => scalar keys %changed, changes => \@diffs };
    } );
}

sub dashboard {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my %dashboard;
    $dashboard{_column_order} = {};
    for my $type ( ( $args{type} // 'all' ) eq 'all' ? qw(sow epic ticket) : ( $args{type} ) ) {
        for my $column ( @{ $self->column_list( project => $root, type => $type ) } ) {
            next if $column->{name} eq 'discard' && !$args{include_discard};
            push @{ $dashboard{_column_order}{$type} }, $column->{name};
            $dashboard{$type}{ $column->{name} } = $self->record_list( project => $root, type => $type, column => $column->{name} );
        }
    }
    return \%dashboard;
}

sub _project_data {
    my ( $self, $root ) = @_;
    my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
    my $data = $self->{yaml}->load_file($path);
    for my $person ( @{ $data->{people} } ) {
        $person->{active} = JSON::PP::true if !exists $person->{active};
    }
    return ( $path, $data );
}

sub _set_person_active {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($person) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if !$person;
        $person->{active} = $args{active};
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

sub _replace_record {
    my ( $self, %args ) = @_;
    my ( $path, undef, $column ) = $self->_record_data(%args);
    my %record = %{ $args{record} };
    delete $record{column};
    $record{last_updated} = $self->{clock}->();
    $self->_write_json( $path, \%record );
    return { %record, column => $column };
}

sub _require_person {
    my ( $self, %args ) = @_;
    my $person = $args{person};
    die "Project person is required\n" if !defined $person || $person eq '';
    die "Unknown project person '$person'\n" if !grep { $_->{id} eq $person } @{ $self->person_list(%args) };
    return $person;
}

sub _require_active_person {
    my ( $self, %args ) = @_;
    my $person = $args{person};
    die "Project person is required\n" if !defined $person || $person eq '';
    my ($match) = grep { $_->{id} eq $person } @{ $self->person_list(%args) };
    die "Unknown project person '$person'\n" if !$match;
    die "Project person '$person' is inactive\n" if exists $match->{active} && !$match->{active};
    return $person;
}

sub _unique_casefold {
    my ( $self, $values ) = @_;
    die "Expected an array of text values\n" if ref($values) ne 'ARRAY';
    my ( %seen, @unique );
    for my $value ( @{$values} ) {
        die "Array values must be non-empty text\n" if !defined $value || ref($value) || $value eq '';
        push @unique, $value if !$seen{ lc $value }++;
    }
    return \@unique;
}

sub _valid_priority {
    my ( $self, $priority ) = @_;
    return undef if !defined $priority || $priority eq '';
    die "Priority must be an integer from 1 to 5\n" if $priority !~ /\A([1-5])\z/;
    return 0 + $1;
}

sub _valid_datetime {
    my ( $self, $value, $label ) = @_;
    return undef if !defined $value || $value eq '';
    die "$label must be an ISO 8601 date-time with timezone\n"
      if $value !~ /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))\z/;
    return $1;
}

sub _reciprocal_type {
    my ( $self, $root, $type ) = @_;
    for my $pair ( @{ $self->link_type_list( project => $root ) } ) {
        return $pair->{inward} if $pair->{outward} eq ( $type // '' );
        return $pair->{outward} if $pair->{inward} eq ( $type // '' );
    }
    die "Unknown link type '$type'\n";
}

sub _is_subitem_descendant {
    my ( $self, $root, $start, $wanted ) = @_;
    return 1 if $start eq $wanted;
    my $record = $self->record_show( project => $root, ref => $start );
    my $key = "sub_$record->{type}_refs";
    for my $child ( @{ $record->{linkage}{$key} } ) {
        return 1 if $self->_is_subitem_descendant( $root, $child, $wanted );
    }
    return 0;
}

sub _attachment_path {
    my ( $self, $root, %args ) = @_;
    my $sha = $args{sha} // '';
    die "Invalid attachment SHA\n" if $sha !~ /\A([0-9a-f]{64})\z/;
    $sha = $1;
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    if ( defined $args{extension} ) {
        die "Invalid attachment extension\n" if $args{extension} !~ /\A([A-Za-z0-9]+)\z/;
        my $extension = $1;
        return File::Spec->catfile( $dir, "$sha.$extension" );
    }
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @matches = map { /\A(\Q$sha\E)\.([A-Za-z0-9]+)\z/ ? File::Spec->catfile( $dir, "$1.$2" ) : () } readdir $dh;
    closedir $dh;
    die "Attachment SHA '$sha' has multiple extensions\n" if @matches > 1;
    return $matches[0];
}

sub _board_data {
    my ( $self, %args ) = @_;
    my $type = $self->_valid_type( $args{type} );
    my $root = $self->discover_project(%args);
    my $path = File::Spec->catfile( $root, '.tira', $type, 'config.yml' );
    my $config = $self->{yaml}->load_file($path);
    $_->{name} = $self->_valid_slug( $_->{name} ) for @{ $config->{columns} };
    return ( $path, $config );
}

sub _record_data {
    my ( $self, %args ) = @_;
    my $ref = $args{ref} // '';
    die "Record reference is required\n" if $ref eq '';
    die "Invalid record reference '$ref'\n" if $ref !~ /\A[A-Z][A-Z0-9-]{0,31}-\d{1,12}\z/;
    my $root = $self->discover_project(%args);
    my @found;
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        find( { no_chdir => 1, wanted => sub {
            push @found, $self->_canonical_path( $File::Find::name, "record '$ref'" )
              if -f $File::Find::name && basename( $File::Find::name ) eq "$ref.json";
        } }, $board );
    }
    die "Record '$ref' not found\n" if !@found;
    die "Duplicate record '$ref' found\n" if @found > 1;
    my $path = $found[0];
    return ( $path, $self->_read_json($path), basename( dirname($path) ) );
}

sub _read_json {
    my ( $self, $path ) = @_;
    open my $fh, '<:raw', $path or die "Cannot read JSON '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close JSON '$path': $!\n";
    my $record = eval { JSON::PP->new->utf8->decode($content) };
    if ( !defined $record ) {
        my $characters = $self->_decode_legacy_utf8($content);
        $record = JSON::PP->new->decode($characters);
    }
    if ( !exists $record->{assignee} && exists $record->{assignees} ) {
        $record->{assignee} = @{ $record->{assignees} // [] } ? $record->{assignees}[0] : undef;
    }
    delete $record->{assignees};
    for my $field (qw(assignee reporter due_date start_date sdlc_gate lifecycle priority fix_version)) {
        $record->{$field} = undef if !exists $record->{$field};
    }
    for my $field (qw(labels affects_versions)) {
        $record->{$field} = [] if !exists $record->{$field};
    }
    for my $index ( 0 .. $#{ $record->{gate_passing_log} // [] } ) {
        my $entry = $record->{gate_passing_log}[$index];
        $entry->{id} //= sprintf( 'GATE-%03d', $index + 1 );
        $entry->{annotations} //= [];
    }
    for my $index ( 0 .. $#{ $record->{evidence} // [] } ) {
        my $entry = $record->{evidence}[$index];
        $entry->{id} //= sprintf( 'EVD-%03d', $index + 1 );
        $entry->{annotations} //= [];
    }
    $record->{checklist} = [] if !exists $record->{checklist};
    $record->{parent} = $record->{linkage}{"parent_$record->{type}_ref"}
      // $record->{linkage}{sow_ref} // $record->{linkage}{epic_ref};
    return $record;
}

sub _valid_slug {
    my ( $self, $slug ) = @_;
    die "Invalid column name\n" if !defined $slug || $slug !~ /\A([a-z0-9]+(?:-[a-z0-9]+)*)\z/;
    return $1;
}

sub _decode_legacy_utf8 {
    my ( $self, $bytes ) = @_;
    my $characters = '';
    while ( length $bytes ) {
        $characters .= decode( 'UTF-8', $bytes, FB_QUIET );
        $characters .= chr unpack( 'C', substr( $bytes, 0, 1, '' ) ) if length $bytes;
    }
    return $characters;
}

sub _valid_type {
    my ( $self, $type ) = @_;
    $type //= '';
    die "Unsupported record type '$type'\n" if $type !~ /\A(sow|epic|ticket)\z/;
    return $1;
}

sub _safe_path_input {
    my ( $self, $path, $label ) = @_;
    die "Unsafe control character in $label\n" if !defined $path || $path =~ /[\x00-\x1f\x7f]/;
    $path =~ /\A(.+)\z/ or die "Cannot validate $label\n";
    return $1;
}

sub format_output {
    my ( $self, $data, %args ) = @_;
    my $output = $args{output} // 'toon';
    if ( $output eq 'toon' ) {
        local $SIG{__WARN__} = sub { };
        return Data::TOON->encode($data) . "\n";
    }
    return JSON::PP->new->canonical->pretty->encode($data) if $output eq 'json';
    return $self->_markdown( $data, %args ) if $output eq 'human';
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
    my ( $self, $data, %args ) = @_;
    if ( ref($data) eq 'HASH' && exists $data->{ref} ) {
        my $description = $data->{description} ne '' ? $data->{description} : '_No description._';
        my %priority = ( 1 => 'Low', 2 => 'Medium Low', 3 => 'Medium', 4 => 'High', 5 => 'Very High' );
        my %names;
        my $people = eval {
            $self->person_list( defined $args{project} ? ( project => $args{project} ) : () );
        } // [];
        %names = map { $_->{id} => $_->{name} } @{$people};
        my $assignee = defined $data->{assignee} ? ( $names{ $data->{assignee} } // $data->{assignee} ) : '_Unassigned_';
        my $reporter = defined $data->{reporter} ? ( $names{ $data->{reporter} } // $data->{reporter} ) : '_None_';
        my $priority = defined $data->{priority} ? $priority{ $data->{priority} } : '_None_';
        my $checklist = @{ $data->{checklist} // [] }
          ? "\n## Checklist\n\n" . join( '', map { "- [$_->{status}] $_->{item}\n" } @{ $data->{checklist} } )
          : "\n## Checklist\n\n_Empty._\n";
        return "# $data->{ref}: $data->{title}\n\n$description\n\n"
          . "- Type: `$data->{type}`\n"
          . "- Assignee: $assignee\n"
          . "- Reporter: $reporter\n"
          . "- Priority: $priority\n"
          . "- Created: $data->{created_at}\n"
          . "- Last Updated: $data->{last_updated}\n"
          . $checklist;
    }
    if ( ref($data) eq 'HASH' && ref( $data->{_column_order} ) eq 'HASH' ) {
        my $markdown = "# Tira Dashboard\n";
        for my $type (qw(sow epic ticket)) {
            next if !exists $data->{_column_order}{$type};
            $markdown .= "\n## " . uc($type) . "\n";
            for my $column ( @{ $data->{_column_order}{$type} } ) {
                $markdown .= "\n### $column\n";
                my $records = $data->{$type}{$column};
                $markdown .= @{$records}
                  ? join( '', map { "- `$_->{ref}` $_->{title}\n" } @{$records} )
                  : "_Empty._\n";
            }
        }
        return $markdown;
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
    my $yaml = $self->{yaml}->dump_string($data);
    $self->_atomic_write( $path, utf8::is_utf8($yaml) ? encode_utf8($yaml) : $yaml );
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
    my $json = JSON::PP->new->canonical->pretty->utf8->encode($data);
    $self->_atomic_write( $path, $json );
}

sub _write_json_transaction {
    my ( $self, $updates ) = @_;
    my %original;
    for my $update ( @{$updates} ) {
        my ($path) = @{$update};
        open my $fh, '<:raw', $path or die "Cannot snapshot '$path': $!\n";
        $original{$path} = do { local $/; <$fh> };
        close $fh or die "Cannot close snapshot '$path': $!\n";
    }
    my $ok = eval {
        $self->_write_json( @{$_} ) for @{$updates};
        1;
    };
    if ( !$ok ) {
        my $error = $@ || 'Unknown multi-record write failure';
        for my $path ( keys %original ) {
            $self->_atomic_write( $path, $original{$path} );
        }
        die $error;
    }
    return 1;
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
the shared TOON, JSON, and Markdown output contract. Text persistence is
canonical UTF-8; legacy isolated bytes are repaired during record reads.
Every work record also supports ordered checklist entries with item/status
values and immutable record-local IDs.

=head1 METHODS

=head2 new

Creates an engine. Tests may supply a C<clock> callback.

=head2 create_project

Creates the canonical project and board layout.

=head2 discover_project

Finds C<.tira/project.yml> by explicit root or upward directory traversal.

=head2 create_record

Creates one free-ranging SOW, epic, or ticket in its Backlog column.
Release 0.03 records include singular assignee, optional reporter, planning and
version metadata, numeric priority, and an immediate generated parent.

=head2 format_output

Encodes data as TOON by default, pretty JSON, or Markdown.

=cut
