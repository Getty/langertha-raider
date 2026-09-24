requires 'File::ShareDir';
requires 'File::Which';
requires 'Future';
requires 'Future::AsyncAwait', '0.66';
requires 'Getopt::Long';
requires 'HTML::TreeBuilder';
requires 'HTTP::Request::Common';
requires 'IO::Async';
requires 'IO::Prompt::Tiny';
requires 'IPC::Run';
requires 'JSON::MaybeXS';
requires 'Langertha', '0.503';
requires 'MCP::Run::Bash', '0.106';
requires 'MCP::Server';
requires 'Module::Runtime';
requires 'Moose';
requires 'Net::Async::HTTP';
requires 'Net::Async::MCP', '0.004';
requires 'Net::Async::WebSearch', '0.003';
requires 'Path::Tiny';
requires 'Schedule::Cron';
requires 'Term::ANSIColor';
requires 'Time::HiRes';
requires 'URI';
requires 'YAML::PP';
requires 'namespace::autoclean', '0.31';

recommends 'Term::Choose';
recommends 'Term::ReadLine::Gnu';
recommends 'Term::Table';

on test => sub {
  requires 'Test2::Suite';
};
