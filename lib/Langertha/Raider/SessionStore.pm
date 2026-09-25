package Langertha::Raider::SessionStore;
# ABSTRACT: Internal store of the session journals of one scope
our $VERSION = '0.503';
use Moose;
use Moose::Util::TypeConstraints qw( enum );
use namespace::autoclean;
use Carp qw( croak );
use Fcntl qw( O_WRONLY O_CREAT O_EXCL );
use POSIX qw( strftime );
use Path::Tiny;
use Time::HiRes ();
use Langertha::Raider::Session;
use Langertha::Raider::Session::Journal;

=head1 SYNOPSIS

    # Internal to Langertha-Raider -- no API promise.
    my $store = Langertha::Raider::SessionStore->new(scope => 'project', root => $dir);

    my $session = $store->create;                 # new journal, locked for writing
    my $run = $session->next_run;                 # 'r1'
    $session->append('run.started', run => $run, engine => 'openai', model => 'gpt-4o');

    my @ids     = $store->ids;                    # newest first
    my $journal = $store->read($ids[0]);          # no lock needed
    my $again   = $store->open($ids[0]);          # croaks "... is in use" while $session lives

=head1 DESCRIPTION

B<Internal module.> Its interface may change without notice.

The session journals of one scope (ADR 0003, ADR 0015): the directory
F<sessions/> under F<< <project>/.raider >> (scope C<project>) or
F<~/.raider> (scope C<home>), one F<< <id>.jsonl >> per session.
L</create> and L</open> hand out a L<Langertha::Raider::Session>, the one
writer of a journal, which holds its lock; L</read> gives a
L<Langertha::Raider::Session::Journal> without taking a lock.

=attr scope

C<project> (the default) or C<home>.

=attr root

The project directory. Required for the C<project> scope.

=attr home

The home directory of the C<home> scope. Defaults to C<$ENV{HOME}>, then
the user's home from the password database.

=cut

has scope => (
  is      => 'ro',
  isa     => enum([qw( project home )]),
  default => 'project',
);

has root => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_root',
);

has home => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_home',
);

sub _build_home { $ENV{HOME} // (getpwuid($<))[7] }

=attr principal

The local user name written into C<session.created>. Defaults to the name
of the real user id, then C<$ENV{USER}>.

=cut

has principal => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_principal',
);

sub _build_principal { scalar(getpwuid($<)) // $ENV{USER} // 'unknown' }

=attr clock

Code reference returning the current time as epoch seconds; the C<time> of
every event and the time in a new id. Defaults to L<Time::HiRes/time>.

=cut

has clock => (
  is      => 'ro',
  isa     => 'CodeRef',
  default => sub { \&Time::HiRes::time },
);

sub session_class { 'Langertha::Raider::Session' }
sub journal_class { 'Langertha::Raider::Session::Journal' }

sub BUILD {
  my ( $self ) = @_;
  croak __PACKAGE__.': the project scope needs a root' if $self->scope eq 'project' && !$self->has_root;
  return;
}

=method base

The scope directory: F<< <root>/.raider >> or F<< <home>/.raider >>, as a
L<Path::Tiny>.

=method dir

The F<sessions> directory under L</base>.

=cut

sub base {
  my ( $self ) = @_;
  return path($self->scope eq 'project' ? $self->root : $self->home)->absolute->child('.raider');
}

sub dir { $_[0]->base->child('sessions') }

=method is_id

    $store->is_id('20260925-081500-3f2a');   # true

Whether the string has the form of a session id,
C<YYYYMMDD-HHMMSS-xxxx>.

=cut

sub is_id {
  my ( $self, $id ) = @_;
  return defined $id && $id =~ /\A\d{8}-\d{6}-[0-9a-f]{4}\z/ ? 1 : 0;
}

=method path_of

    my $file = $store->path_of($id);

The journal file of a session id. Croaks on a string that is no id, so no
path outside L</dir> can be built from user input.

=cut

sub path_of {
  my ( $self, $id ) = @_;
  croak 'not a session id: '.($id // '(undef)') unless $self->is_id($id);
  return $self->dir->child($id.'.jsonl');
}

=method exists

True when the session has a journal in this scope.

=cut

sub exists {
  my ( $self, $id ) = @_;
  return $self->is_id($id) && -f $self->path_of($id) ? 1 : 0;
}

=method ids

The ids of the sessions in this scope, newest first. Empty when there is
no F<sessions> directory.

=cut

sub ids {
  my ( $self ) = @_;
  my $dir = $self->dir;
  return () unless -d $dir;
  return reverse sort grep { $self->is_id($_) }
    map { $_->basename('.jsonl') } $dir->children(qr/\.jsonl\z/);
}

=method latest

The id of the newest session, or C<undef>.

=cut

sub latest { ( $_[0]->ids )[0] }

=method is_ref

    $store->is_ref('3f2a');            # true
    $store->is_ref('20260925-0815');   # true

Whether the string can name a session on the command line: a whole id, the
start of one (at least four characters), or the four hex digits at its end.
Also works as a class method. L</resolve> finds the session it names.

=cut

sub is_ref {
  my ( $self, $ref ) = @_;
  return 0 unless defined $ref && length $ref >= 4 && length $ref <= 20;
  return 1 if $ref =~ /\A[0-9a-f]{4}\z/;
  return $self->is_id($ref.substr('00000000-000000-0000', length $ref));
}

=method resolve

    my $id = $store->resolve('3f2a');

The id of the one session a reference (L</is_ref>) names: the session with
that id, else the one whose id starts with it or ends in C<-REF>. Croaks
C<unknown session REF> when there is none, and C<session REF is
ambiguous: ID, ID> (newest first) when there is more than one.

=cut

sub resolve {
  my ( $self, $ref ) = @_;
  croak 'unknown session '.($ref // '(undef)') unless $self->is_ref($ref);
  return $ref if $self->exists($ref);
  my @ids = grep { index($_, $ref) == 0 || substr($_, -5) eq '-'.$ref } $self->ids;
  croak 'unknown session '.$ref unless @ids;
  croak 'session '.$ref.' is ambiguous: '.join(', ', @ids) if @ids > 1;
  return $ids[0];
}

=method prepare_base

Creates L</base>. In the C<project> scope it also writes
F<.raider/.gitignore> excluding C<sessions/> and C<lib/> when there is
none, so journals and the local::lib of the Perl tools are never committed
by default. Whatever creates F<.raider/> goes through here.

=method prepare

L</prepare_base>, then creates L</dir>.

=cut

sub prepare_base {
  my ( $self ) = @_;
  $self->base->mkpath;
  if ($self->scope eq 'project') {
    my $ignore = $self->base->child('.gitignore');
    $ignore->spew_utf8("sessions/\nlib/\n") unless -e $ignore;
  }
  return;
}

sub prepare {
  my ( $self ) = @_;
  $self->prepare_base;
  $self->dir->mkpath;
  return;
}

=method new_id

A fresh id for the current time: C<YYYYMMDD-HHMMSS> in UTC and four
random hex digits.

=cut

sub new_id {
  my ( $self ) = @_;
  return strftime('%Y%m%d-%H%M%S', gmtime int $self->clock->()).'-'.sprintf('%04x', int rand 0x10000);
}

=method create

    my $session = $store->create;
    my $fork    = $store->create(forked_from => $id);

Starts a new session: L</prepare>, claims a fresh id (a file that already
exists is never reused), locks it and writes C<session.created> as line 1
-- C<id>, C<scope>, C<root> (the project, or the home directory),
C<principal> and C<raider> (the version), plus the given fields (which
never replace those).

=cut

sub create {
  my ( $self, %fields ) = @_;
  $self->prepare;
  my ( $id, $path );
  for my $try (1 .. 100) {
    $id   = $self->new_id;
    $path = $self->path_of($id);
    if (sysopen my $fh, $path, O_WRONLY | O_CREAT | O_EXCL) {
      close $fh;
      last;
    }
    croak 'cannot create '.$path.': '.$! unless $!{EEXIST} && $try < 100;
  }
  my $session = $self->session_class->new(id => $id, path => $path, clock => $self->clock);
  $session->append('session.created',
    %fields,
    id        => $id,
    scope     => $self->scope,
    root      => $self->scope eq 'project' ? path($self->root)->absolute->stringify : $self->home,
    principal => $self->principal,
    raider    => $VERSION,
  );
  return $session;
}

=method open

    my $session = $store->open($id);

Opens an existing session for writing. Croaks C<unknown session ID> when it
has no journal here, and C<session ID is in use> when another writer holds
its lock -- at once, without waiting.

=cut

sub open {
  my ( $self, $id ) = @_;
  croak 'unknown session '.($id // '(undef)') unless $self->exists($id);
  return $self->session_class->new(id => $id, path => $self->path_of($id), clock => $self->clock);
}

=method read

    my $journal = $store->read($id);

The L<Langertha::Raider::Session::Journal> of a session, read without a
lock. Croaks C<unknown session ID> when there is none.

=cut

sub read {
  my ( $self, $id ) = @_;
  croak 'unknown session '.($id // '(undef)') unless $self->exists($id);
  return $self->journal_class->load($self->path_of($id), id => $id);
}

=method remove

    $store->remove($id);

Deletes a session: its journal and its lock file. It takes the lock first,
so it croaks C<session ID is in use> -- at once -- while another writer has
the session open, and C<unknown session ID> when there is none. Nothing in
Raider removes a session on its own.

=cut

sub remove {
  my ( $self, $id ) = @_;
  my $session = $self->open($id);
  path($session->path)->remove or croak 'cannot remove '.$session->path.': '.$!;
  path($session->lock_path)->remove;
  $session->release;
  return;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Session>

=item * L<Langertha::Raider::Session::Journal>

=back

=cut
