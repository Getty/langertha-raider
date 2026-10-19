package Langertha::Raider::TodoTools;
# ABSTRACT: Internal task-list tool of raider: todo_write
our $VERSION = '0.504';
use Moose;
use namespace::autoclean;
use Carp qw( croak );
use MCP::Server;

=synopsis

    my $todos  = Langertha::Raider::TodoTools->new( on_update => sub { my ($list) = @_; ... } );
    my $server = $todos->server;      # MCP::Server with the tool todo_write

=description

B<Internal module.> Its interface may change without notice.

The C<todo_write> tool, shaped after Claude Code's C<TodoWrite>
(L<Langertha::Raider::ToolNames>): the model keeps a list of the steps of
a larger task and sends the whole list on every change. The tool holds no
list of its own; it checks the list it is given and hands it to
L</on_update>, which keeps it in the state of the run and reports the
change (L<Langertha::Raider::Application/todos>, the C<todo.updated>
event). It has no effect outside the run.

An item has a C<content> (what to do, imperative), a C<status>
(C<pending>, C<in_progress> or C<completed>) and an optional C<activeForm>
(the same in the present continuous, for a progress display; it defaults to
the content). At most one item is C<in_progress>: the list says what the
model does now.

=cut

has on_update => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_on_update',
);

=attr on_update

Optional. Called with the checked list (an array reference of hashes with
C<content>, C<status> and C<activeForm>) when a call replaced the list.

=cut

has server => (
  is       => 'ro',
  lazy     => 1,
  builder  => '_build_server',
  init_arg => undef,
);

=attr server

The L<MCP::Server> with the tool C<todo_write>, built once.

=cut

my @STATUS = qw( pending in_progress completed );
my %MARK   = ( pending => '[ ]', in_progress => '[>]', completed => '[x]' );

=method check

    my $list = $todos->check( \@items );

The list as the tool stores it, or a croak naming the first item that is
wrong: not a hash, no C<content>, an unknown C<status>, or a second
C<in_progress> item.

=cut

sub check {
  my ( $self, $items ) = @_;
  croak 'todos must be a list' unless ref $items eq 'ARRAY';
  my ( @list, $active );
  for my $i ( 0 .. $#$items ) {
    my $n    = $i + 1;
    my $item = $items->[$i];
    croak 'todo '.$n.' is not an object' unless ref $item eq 'HASH';
    my $content = $item->{content};
    croak 'todo '.$n.' has no content' unless defined $content && !ref $content && $content =~ /\S/;
    my $status = $item->{status} // '';
    croak 'todo '.$n.' has the status "'.$status.'", expected one of '.join( ', ', @STATUS )
      unless grep { $_ eq $status } @STATUS;
    croak 'todo '.$n.' is a second item in_progress (todo '.$active.' is): only one at a time'
      if $status eq 'in_progress' && defined $active;
    $active = $n if $status eq 'in_progress';
    push @list, {
      content    => $content,
      status     => $status,
      activeForm => ( defined $item->{activeForm} && length $item->{activeForm} ? $item->{activeForm} : $content ),
    };
  }
  return \@list;
}

=method render

    my $text = $todos->render($list);

The list as the tool answers it: a count line, then one line per item.

=cut

sub render {
  my ( $self, $list ) = @_;
  return 'Todo list is empty.' unless @$list;
  my %count;
  $count{ $_->{status} }++ for @$list;
  return 'Todo list updated: '
    .join( ', ', map { ( $count{$_} // 0 ).' '.( s/_/ /r ) } reverse @STATUS )."\n"
    .join( "\n", map { $MARK{ $_->{status} }.' '.$_->{content} } @$list );
}

sub _build_server {
  my ( $self ) = @_;
  my $server = MCP::Server->new( name => 'raider-todos', version => '1.0' );
  $server->tool(
    name         => 'todo_write',
    description  => 'Keep the list of steps of a larger task (three or more steps). Send the whole list on every change: '
      .'each item has content (imperative), status (pending, in_progress, completed) and activeForm (present continuous). '
      .'Exactly one item is in_progress while you work; mark an item completed as soon as it is done. '
      .'Do not use it for a single simple step.',
    input_schema => {
      type       => 'object',
      properties => {
        todos => {
          type  => 'array',
          items => {
            type       => 'object',
            properties => {
              content    => { type => 'string', description => 'What to do, imperative: "Run the tests"' },
              status     => { type => 'string', enum => \@STATUS },
              activeForm => { type => 'string', description => 'The same in the present continuous: "Running the tests"' },
            },
            required => [qw( content status )],
          },
          description => 'The complete list; it replaces the previous one',
        },
      },
      required => ['todos'],
    },
    code => sub {
      my ( $tool, $in ) = @_;
      my $list = eval { $self->check( $in->{todos} ) };
      if ($@) {
        ( my $msg = $@ ) =~ s/\s+at \S+ line \d+\.?\s*\z//;
        return $tool->text_result( 'Error: '.$msg, 1 );
      }
      $self->on_update->($list) if $self->has_on_update;
      return $tool->text_result( $self->render($list) );
    },
  );
  return $server;
}

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over

=item * L<Langertha::Raider::Application>

=item * L<Langertha::Raider::ToolNames>

=back

=cut
