package Langertha::Raider::FileTools;
our $VERSION = '0.504';
# ABSTRACT: MCP::Server factory with local filesystem tools (list/read/write/edit)

use strict;
use warnings;
use Cwd qw( realpath );
use Path::Tiny;
use MCP::Server;

use Exporter 'import';
our @EXPORT_OK = qw( build_file_tools_server );

=description

The file tools of L<raider>: an L<MCP::Server> with C<list_files(path)>,
C<read_file(path)>, C<write_file(path, content)> and
C<edit_file(path, old_string, new_string, replace_all)>, confined to one
directory. C<edit_file> replaces C<old_string> where it occurs exactly once,
or every occurrence with C<replace_all> (as Claude Code's C<Edit>).

=func build_file_tools_server

    my $server = Langertha::Raider::FileTools::build_file_tools_server(
        root        => '/some/dir',     # optional confinement root
        extra_roots => [ '/other/dir' ], # optional: more directories allowed
        # or a CodeRef returning the list, asked on every call:
        # extra_roots => sub { [ '/other/dir' ] },
    );

Returns an L<MCP::Server> instance with the tools C<list_files>, C<read_file>,
C<write_file>, and C<edit_file> registered. When C<root> is set, all path
arguments are confined to that directory and the C<extra_roots> (the
additional directories of ADR 0021); relative paths are read against
C<root>. Existing paths and nearest existing parents are resolved with
C<realpath>, so symlinks cannot be used to escape them. An extra root that
does not exist is left out. C<extra_roots> may be a CodeRef that returns the
list (or an ArrayRef); it is called on every tool call, so the application can
change the additional directories while the server is mounted (C</reload>).

=cut

sub build_file_tools_server {
  my %args = @_;
  my $root = defined $args{root} ? path($args{root})->absolute : undef;
  my $root_realpath = $root ? realpath($root) : undef;
  die "Root does not exist: $root\n" if $root && !defined $root_realpath;
  my $real_root = $root ? path($root_realpath)->absolute : undef;
  my $extra = $args{extra_roots};
  my $real_roots = sub {
    my @extra = ref $extra eq 'CODE' ? $extra->() : @{ $extra // [] };
    @extra = @{ $extra[0] } if @extra == 1 && ref $extra[0] eq 'ARRAY';
    return ( $real_root, map { path($_)->absolute } grep { defined } map { realpath($_) } grep { defined } @extra );
  };

  my $assert_in_root = sub {
    my ($p) = @_;
    return unless $real_root;
    my @real_roots = $real_roots->();
    die "Path escapes root: $p\n" unless grep { $_->subsumes($p) } @real_roots;
    return;
  };

  my $nearest_existing = sub {
    my ($p) = @_;
    my $cur = $p;
    while (!-e $cur) {
      my $parent = $cur->parent;
      die "No existing parent for $p\n" if "$parent" eq "$cur";
      $cur = $parent;
    }
    return $cur;
  };

  my $resolve = sub {
    my ($path) = @_;
    my $p = path($path);
    if ($root) {
      $p = $p->is_absolute ? $p : $root->child($path);
      $p = $p->absolute;
      my $existing = $nearest_existing->($p);
      my $existing_realpath = realpath($existing)
        or die "Cannot resolve path: $existing\n";
      my $real_existing = path($existing_realpath)->absolute;
      $assert_in_root->($real_existing);
      if (-e $p) {
        my $p_realpath = realpath($p)
          or die "Cannot resolve path: $p\n";
        my $real_p = path($p_realpath)->absolute;
        $assert_in_root->($real_p);
        $p = $real_p;
      }
    }
    return $p;
  };

  my $resolve_for_write = sub {
    my ($path) = @_;
    my $p = $resolve->($path);
    return $p if -e $p;
    my $parent = $p->parent;
    my $existing = $nearest_existing->($parent);
    my $existing_realpath = realpath($existing)
      or die "Cannot resolve path: $existing\n";
    my $real_existing = path($existing_realpath)->absolute;
    $assert_in_root->($real_existing);
    return $p;
  };

  my $server = MCP::Server->new(name => 'raider-files', version => '1.0');

  $server->tool(
    name         => 'list_files',
    description  => 'List entries in a directory. Directories are suffixed with "/".',
    input_schema => {
      type       => 'object',
      properties => { path => { type => 'string', description => 'Directory path' } },
      required   => ['path'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $p = eval { $resolve->($in->{path}) };
      return $tool->text_result("Error: $@", 1) if $@;
      return $tool->text_result("Error: not a directory: $p", 1) unless -d $p;
      my @entries = sort map { -d $_ ? $_->basename . '/' : $_->basename } $p->children;
      return $tool->text_result(join("\n", @entries));
    },
  );

  $server->tool(
    name         => 'read_file',
    description  => 'Read the full contents of a text file.',
    input_schema => {
      type       => 'object',
      properties => { path => { type => 'string', description => 'File path' } },
      required   => ['path'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $p = eval { $resolve->($in->{path}) };
      return $tool->text_result("Error: $@", 1) if $@;
      return $tool->text_result("Error: not a file: $p", 1) unless -f $p;
      my $content = eval { $p->slurp_utf8 };
      return $tool->text_result("Error reading $p: $@", 1) if $@;
      return $tool->text_result($content);
    },
  );

  $server->tool(
    name         => 'write_file',
    description  => 'Write contents to a file. Creates parent directories, overwrites existing files.',
    input_schema => {
      type       => 'object',
      properties => {
        path    => { type => 'string', description => 'File path' },
        content => { type => 'string', description => 'Full file contents' },
      },
      required => ['path', 'content'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $p = eval { $resolve_for_write->($in->{path}) };
      return $tool->text_result("Error: $@", 1) if $@;
      eval {
        $p->parent->mkpath unless -d $p->parent;
        $p->spew_utf8($in->{content});
      };
      return $tool->text_result("Error writing $p: $@", 1) if $@;
      return $tool->text_result("Wrote " . length($in->{content}) . " bytes to $p");
    },
  );

  $server->tool(
    name         => 'edit_file',
    description  => 'Replace an exact substring in a file (old_string must match exactly once, unless replace_all is set).',
    input_schema => {
      type       => 'object',
      properties => {
        path        => { type => 'string', description => 'File path' },
        old_string  => { type => 'string', description => 'Exact text to replace' },
        new_string  => { type => 'string', description => 'Replacement text' },
        replace_all => { type => 'boolean', description => 'Replace every occurrence of old_string (default false)' },
      },
      required => ['path', 'old_string', 'new_string'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $p = eval { $resolve->($in->{path}) };
      return $tool->text_result("Error: $@", 1) if $@;
      return $tool->text_result("Error: not a file: $p", 1) unless -f $p;
      my $content = eval { $p->slurp_utf8 };
      return $tool->text_result("Error reading $p: $@", 1) if $@;
      my $old = $in->{old_string};
      my $count = () = $content =~ /\Q$old\E/g;
      return $tool->text_result("Error: old_string not found", 1) if $count == 0;
      return $tool->text_result("Error: old_string matches $count times, must be unique (or set replace_all)", 1)
        if $count > 1 && !$in->{replace_all};
      if ( $in->{replace_all} ) {
        $content =~ s/\Q$old\E/$in->{new_string}/g;
      }
      else {
        $content =~ s/\Q$old\E/$in->{new_string}/;
      }
      eval { $p->spew_utf8($content) };
      return $tool->text_result("Error writing $p: $@", 1) if $@;
      return $tool->text_result("Edited $p");
    },
  );

  return $server;
}

1;

=seealso

=over

=item * L<MCP::Server>

=item * L<Langertha::Raider::CLI>

=back

=cut
