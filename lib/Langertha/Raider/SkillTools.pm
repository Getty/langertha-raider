package Langertha::Raider::SkillTools;
our $VERSION = '0.504';
# ABSTRACT: Internal MCP::Server factory with the skill tool (load a skill on demand)

use strict;
use warnings;
use Carp qw( croak );
use MCP::Server;

use Exporter 'import';
our @EXPORT_OK = qw( build_skill_tools_server );

=description

B<Internal module.> Its interface may change without notice.

The C<skill> tool of ADR 0019 §4: an L<MCP::Server> with one tool,
C<skill(skill, args?)>, that returns a skill of a
L<Langertha::Raider::Context::Skills> catalogue in the shape of Claude
Code's Skill tool -- C<Base directory for this skill: DIR>, then the body
without frontmatter, C<$ARGUMENTS> replaced (see
L<Langertha::Raider::Context::Skills/tool_text>). The system prompt lists
the skills (L<Langertha::Raider::Context::Skills/prompt_text>); the tool
loads one. Mount it only when the catalogue lists at least one skill.

=func build_skill_tools_server

    my $server = Langertha::Raider::SkillTools::build_skill_tools_server(
        skills => $catalogue,   # Langertha::Raider::Context::Skills
    );

Returns an L<MCP::Server> with the tool C<skill>. A name the catalogue does
not know, or a skill that is not model-invocable
(C<disable-model-invocation: true>), is an error result naming the listed
skills. Croaks without C<skills>.

=cut

sub build_skill_tools_server {
  my %args = @_;
  my $skills = $args{skills}
    or croak __PACKAGE__.'::build_skill_tools_server needs skills';

  my $server = MCP::Server->new(name => 'raider-skills', version => '1.0');

  $server->tool(
    name         => 'skill',
    description  => 'Execute a skill within the conversation. Skills are specialised '
      .'instructions and domain knowledge, loaded on demand; the available skills are '
      .'listed in the system prompt with their descriptions. When a task matches a '
      .'skill, call this tool with its name BEFORE acting on the task, then follow the '
      .'instructions it returns. Only call skills that are listed, and do not load a '
      .'skill again whose instructions are already in the conversation.',
    input_schema => {
      type       => 'object',
      properties => {
        skill => {
          type        => 'string',
          description => 'The skill name, e.g. "pdf" or "plugin:skill"',
        },
        args => {
          type        => 'string',
          description => 'Optional arguments for the skill',
        },
      },
      required => ['skill'],
    },
    code => sub {
      my ( $tool, $in ) = @_;
      my $name = $in->{skill};
      $name = '' unless defined $name && !ref $name;
      $name =~ s/\A\s+|\s+\z//g;
      my $skill = length $name ? $skills->find($name) : undef;
      unless ($skill && $skills->is_listed($skill)) {
        my @listed = map { $_->{name} } $skills->listed;
        return $tool->text_result('Error: unknown skill: '.( length $name ? $name : '(none given)' )
          .'. '.( @listed ? 'Available skills: '.join(', ', @listed) : 'No skills are available.' ), 1);
      }
      my $args = $in->{args};
      $args = undef if ref $args;
      return $tool->text_result($skills->tool_text($skill->{name}, $args));
    },
  );

  return $server;
}

1;

=seealso

=over

=item * L<Langertha::Raider::Context::Skills>

=item * L<Langertha::Raider::FileTools>

=back

=cut
