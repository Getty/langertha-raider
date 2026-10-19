#!/usr/bin/env perl
# ABSTRACT: Scenario suite: a scripted model drives the real raider and its real tools (t/scenarios/*.yml)
use strict;
use warnings;
use utf8;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";
use Path::Tiny;
use YAML::PP;
BEGIN {
  eval { require Langertha::Engine::Virtual; 1 }
    or plan skip_all => 'needs Langertha::Engine::Virtual (Langertha 0.504 or later)';
}
use Test::Raider::MockAI qw( mock_app );
use Test::Raider::FakeProc qw( fake_proc );
use Langertha::Raider::Loadguard;

# Each F<t/scenarios/NN-name.yml> is one step of what raider has to do end to
# end. The model is scripted (Test::Raider::MockAI); the application, the raid
# loop and the stock tools are real, working inside a fresh temporary root.
#
#   title:   what the scenario shows
#   files:   { path => content }        written to the root before the run
#   age:     { path => seconds }        how long ago the file was last modified (default: now)
#   proc:    { memory_full, swap, cpus, processes }  a fake /proc the loadguard gate measures
#            (Test::Raider::FakeProc); with it the gate is on, without it off
#   env:     { LOADGUARD_* => value }   the environment of that gate
#   ask:     [ answer, ... ]            the person at the keyboard; ask_user gets these in order
#            (without the key nobody can answer)
#   home:    { path => content }        written to the home: every scenario runs
#            with $HOME at a fresh temporary directory and no
#            $CLAUDE_CONFIG_DIR, so none sees the real ~/.raider or ~/.claude;
#            %ENV is restored after each scenario. In the content of both,
#            and in the strings of `script:`, {{HOME}} and {{ROOT}} stand for
#            the two directories.
#   executable: [ path, ... ]           files of `files:` (or of `home:`, as ~/path)
#            made executable -- hook scripts
#   run_prompt: true                    run each prompt as Application->run_prompt
#            (the whole run: hooks before the prompt and after the answer,
#            ADR 0022) instead of Application->run; the answer is its response
#   app:     { argument => value }      more arguments for the application
#            (e.g. bare: 1, claude: 1)
#   permission_mode: the mode as --permission-mode would give it (ADR 0021).
#            Without the key a scenario runs in bypassPermissions: scenarios
#            test tools, not approvals, unless they say otherwise. `null`
#            gives none, so the mode comes from the config files and the
#            Claude settings (else default). Without `approve:` nobody approves
#            anything: a call the policy asks about is refused, as in a
#            one-shot run.
#   approve: [ once | session | no | 'no: reason', ... ]  the person approving
#            tool calls, one answer per question in order (as the REPL's 1/2/3);
#            when the list runs out the answer is no
#   review:  [ yes | no | 'no: feedback', ... ]  the person reviewing plans of
#            exit_plan_mode, in order (without the key nobody reviews)
#   prompt:  the user prompt (or `prompts:`, a list run one after the other on
#            the same raider, so the conversation carries over)
#   script:  the model's answers, one per request:
#              - tool_calls: [ [ tool_name, { arguments } ], ... ]
#              - text: the final answer
#   expect:
#     answer:      the final answer, exactly
#     outcome:     { status, error } of the last run_prompt (error: a regex)
#     files:       { path => content }  must exist afterwards with this content
#     absent:      [ path, ... ]        must not exist afterwards
#     requests:    [ { index: N, contains: text, absent: text } ] -- the text of the
#                  conversation the model saw in request N (0-based)
#     events:      [ { type => ..., fields } ] events of the application, in order; each
#                  is matched (as a subset) by the next event of its type
#     questions:   [ { question => ..., options => [...] } ] what ask_user put to the person
#     permissions: [ { tool, rule, reason, ... } ] the calls the person was asked to approve,
#                  each matched as a subset (rule: what "for this session" would add)
#     plans:       [ text, ... ] the plans put to the person
#     todos:       [ { content, status } ] the task list at the end
#     tools:       one entry per tool call, in order:
#                    name:   the tool
#                    error:  true if the call must have failed (default false)
#                    text:   regex the result text must match
#                    not_text: regex it must not match
#
# A new scenario is a new file; nothing here changes. Only the scenarios in
# `skip:` (a reason string) are skipped, so a known gap stays visible.

my $yaml  = YAML::PP->new( boolean => 'JSON::PP' );
my @files = sort glob "$FindBin::Bin/scenarios/*.yml";
ok( scalar @files, 'there are scenarios' );

for my $file (@files) {
  my $s    = $yaml->load_file($file);
  my $name = path($file)->basename;
  subtest "$name: " . ( $s->{title} // '' ) => sub {
    skip_all $s->{skip} if $s->{skip};
    local %ENV = %ENV;
    my @tmp  = ( Path::Tiny->tempdir, Path::Tiny->tempdir );   # held: removed at the end
    my ( $root, $home ) = map { $_->realpath } @tmp;
    $ENV{HOME} = "$home";
    delete $ENV{CLAUDE_CONFIG_DIR};
    my $fill = sub { ( my $t = $_[0] ) =~ s/\{\{HOME\}\}/$home/g; $t =~ s/\{\{ROOT\}\}/$root/g; $t };
    $root->child($_)->touchpath->spew_utf8( $fill->( $s->{files}{$_} ) ) for keys %{ $s->{files} // {} };
    $home->child($_)->touchpath->spew_utf8( $fill->( $s->{home}{$_} ) ) for keys %{ $s->{home} // {} };
    ( m{\A~/(.+)\z}s ? $home->child($1) : $root->child($_) )->chmod(0755) for @{ $s->{executable} // [] };

    for my $path ( keys %{ $s->{age} // {} } ) {
      my $t = time - $s->{age}{$path};
      utime $t, $t, "$root/$path";
    }
    my ( @events, @questions, @gate, $proc_dir, @asked, @plans );
    if ( my $proc = $s->{proc} ) {
      $proc_dir = fake_proc(%$proc);    # kept for the whole scenario
      push @gate, loadguard => Langertha::Raider::Loadguard->new( proc_dir => "$proc_dir", env => $s->{env} // {} );
    }
    my @answers = @{ $s->{ask} // [] };
    my @approve = @{ $s->{approve} // [] };
    my @review  = @{ $s->{review} // [] };
    my $answer_of = sub {
      my ( $a ) = @_;
      return { answer => 'no' } unless defined $a;
      return { answer => 'no', reason => $1 } if $a =~ /\Ano:\s*(.*)\z/s;
      return { answer => $a };
    };
    my $deep_fill;
    $deep_fill = sub {
      my ( $v ) = @_;
      return ref $v eq 'HASH' ? { map { $_ => $deep_fill->( $v->{$_} ) } keys %$v }
           : ref $v eq 'ARRAY' ? [ map { $deep_fill->($_) } @$v ]
           : defined $v && !ref $v ? $fill->($v)
           : $v;
    };
    my $app = mock_app(
      root => "$root", script => $deep_fill->( $s->{script} // [] ), @gate,
      permission_mode => exists $s->{permission_mode} ? $s->{permission_mode} : 'bypassPermissions',
      %{ $s->{app} // {} },
      on_event => sub { my ( $type, %p ) = @_; push @events, { type => $type, %p } },
      $s->{ask} ? ( on_ask_user => sub { push @questions, { question => $_[0], options => $_[1] }; shift @answers } ) : (),
      $s->{approve} ? ( on_permission_request => sub { push @asked, $_[0]; $answer_of->( shift @approve ) } ) : (),
      $s->{review} ? ( on_plan_review => sub {
        push @plans, $_[0];
        my $r = shift(@review) // 'no';
        return $r =~ /\A(?:yes|y)\z/ ? { approve => 1 } : { approve => 0, $r =~ /\Ano:\s*(.*)\z/s ? ( feedback => $1 ) : () };
      } ) : (),
    );
    my @prompts = $s->{prompts} ? @{ $s->{prompts} } : ( $s->{prompt} // 'go' );
    my ( $answer, $outcome );
    for my $p (@prompts) {
      $answer = eval {
        return '' . $app->run($p) unless $s->{run_prompt};
        $outcome = $app->run_prompt($p);
        return $outcome->{response};
      };
    }
    is( $@, '', 'the raid finishes' );
    my $expect = $s->{expect} // {};

    is( $answer, $expect->{answer}, 'final answer' ) if exists $expect->{answer};
    if ( my $want = $expect->{outcome} ) {
      is( $outcome->{status}, $want->{status}, 'run status' ) if exists $want->{status};
      like( $outcome->{error} // '', qr/$want->{error}/s, 'run error' ) if defined $want->{error};
    }

    for my $p ( sort keys %{ $expect->{files} // {} } ) {
      ok( $root->child($p)->is_file, "$p exists" )
        && is( $root->child($p)->slurp_utf8, $expect->{files}{$p}, "$p content" );
    }
    ok( !$root->child($_)->exists, "$_ absent" ) for @{ $expect->{absent} // [] };

    for my $r ( @{ $expect->{requests} // [] } ) {
      my $req = $app->mock_engine->requests->[ $r->{index} ];
      ok( $req, "request $r->{index} was made" ) or next;
      my $seen = join "\n", map {
        my $c = $_->{content};
        ref $c ? join( ' ', map { $_->{text} // '' } @$c ) : ( $c // '' )
      } @{ $req->{body}{messages} // [] };
      like( $seen, qr/\Q$r->{contains}\E/, "request $r->{index} contains '$r->{contains}'" ) if defined $r->{contains};
      unlike( $seen, qr/\Q$r->{absent}\E/, "request $r->{index} lacks '$r->{absent}'" ) if defined $r->{absent};
    }

    if ( my $want = $expect->{events} ) {
      my @pool = @events;
      for my $w (@$want) {
        shift @pool while @pool && $pool[0]{type} ne $w->{type};
        my $e = shift @pool;
        ok( $e, "event $w->{type}" ) && like( $e, $w, "event $w->{type}: fields" );
      }
    }
    is( \@questions, $expect->{questions}, 'questions put to the person' ) if $expect->{questions};
    if ( my $want = $expect->{permissions} ) {
      is( scalar @asked, scalar @$want, 'number of approvals asked for' );
      like( $asked[$_], $want->[$_], "approval $_ asked for" ) for 0 .. $#$want;
    }
    is( \@plans, $expect->{plans}, 'plans put to the person' ) if $expect->{plans};
    is( [ map { +{ content => $_->{content}, status => $_->{status} } } @{ $app->todos } ], $expect->{todos}, 'the task list' )
      if $expect->{todos};

    if ( my $want = $expect->{tools} ) {
      my @got = @{ $app->mock_engine->results };
      is( scalar @got, scalar @$want, 'number of tool calls' );
      for my $i ( 0 .. $#$want ) {
        my $w = $want->[$i];
        my $g = $got[$i] or next;
        my $text = join "\n", map { $_->{text} // '' } @{ $g->{result}{content} // [] };
        my $tag  = "tool $i ($w->{name})";
        is( $g->{tool_call}{name}, $w->{name}, "$tag: name" );
        is( !!$g->{result}{isError}, !!$w->{error}, "$tag: " . ( $w->{error} ? 'fails' : 'succeeds' ) );
        like( $text, qr/$w->{text}/s, "$tag: result text" ) if defined $w->{text};
        unlike( $text, qr/$w->{not_text}/s, "$tag: result text excludes" ) if defined $w->{not_text};
      }
    }
  };
}

done_testing;
