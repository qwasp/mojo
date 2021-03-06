package Mojolicious::Renderer;
use Mojo::Base -base;

use File::Spec::Functions 'catfile';
use Mojo::Cache;
use Mojo::JSON;
use Mojo::Home;
use Mojo::Loader;
use Mojo::Util qw(decamelize encode slurp);

has cache   => sub { Mojo::Cache->new };
has classes => sub { ['main'] };
has default_format => 'html';
has 'default_handler';
has encoding => 'UTF-8';
has handlers => sub {
  {
    data => sub { ${$_[2]} = $_[3]{data} },
    text => sub { ${$_[2]} = $_[3]{text} },
    json => sub { ${$_[2]} = Mojo::JSON->new->encode($_[3]{json}) }
  };
};
has helpers => sub { {} };
has paths   => sub { [] };

# Bundled templates
my $HOME = Mojo::Home->new;
$HOME->parse(
  $HOME->parse($HOME->mojo_lib_dir)->rel_dir('Mojolicious/templates'));
my %TEMPLATES = map { $_ => slurp $HOME->rel_file($_) } @{$HOME->list_files};

sub accepts {
  my ($self, $c) = (shift, shift);

  # List representations
  my $req = $c->req;
  my @exts = @{$c->app->types->detect($req->headers->accept, $req->is_xhr)};
  if (!@exts && (my $format = $c->stash->{format} || $req->param('format'))) {
    push @exts, $format;
  }
  return \@exts unless @_;

  # Find best representation
  for my $ext (@exts) {
    return $ext if grep { $ext eq $_ } @_;
  }
  return @exts ? undef : shift;
}

sub add_handler { shift->_add(handlers => @_) }
sub add_helper  { shift->_add(helpers  => @_) }

sub get_data_template {
  my ($self, $options) = @_;

  # Index DATA templates
  my $loader = Mojo::Loader->new;
  unless ($self->{index}) {
    my $index = $self->{index} = {};
    for my $class (reverse @{$self->classes}) {
      $index->{$_} = $class for keys %{$loader->data($class)};
    }
  }

  # Find template
  my $template = $self->template_name($options);
  return $loader->data($self->{index}{$template}, $template);
}

sub render {
  my ($self, $c, $args) = @_;
  $args ||= {};

  # Localize "extends" and "layout" to allow argument overrides
  my $stash = $c->stash;
  local $stash->{layout}  = $stash->{layout}  if exists $stash->{layout};
  local $stash->{extends} = $stash->{extends} if exists $stash->{extends};
  delete @{$stash}{qw(layout extends)}
    if my $partial = delete $args->{partial};

  # Merge stash and arguments
  @{$stash}{keys %$args} = values %$args;

  my $options = {
    encoding => $self->encoding,
    handler  => $stash->{handler},
    template => delete $stash->{template}
  };
  my $inline = $options->{inline} = delete $stash->{inline};
  $options->{handler} //= $self->default_handler if defined $inline;
  $options->{format} = $stash->{format} || $self->default_format;

  # Data
  my $output;
  if (defined(my $data = delete $stash->{data})) {
    $self->handlers->{data}->($self, $c, \$output, {data => $data});
    return $output, $options->{format};
  }

  # JSON
  elsif (my $json = delete $stash->{json}) {
    $self->handlers->{json}->($self, $c, \$output, {json => $json});
    return $output, 'json';
  }

  # Text
  elsif (defined(my $text = delete $stash->{text})) {
    $self->handlers->{text}->($self, $c, \$output, {text => $text});
  }

  # Template or templateless handler
  else {
    $options->{template} ||= $self->template_for($c);
    return unless $self->_render_template($c, \$output, $options);
  }

  # Extends
  my $content = $stash->{'mojo.content'} ||= {};
  local $content->{content} = $output if $stash->{extends} || $stash->{layout};
  while ((my $extends = $self->_extends($stash)) && !defined $inline) {
    @$options{qw(handler template)} = ($stash->{handler}, $extends);
    $options->{format} = $stash->{format} || $self->default_format;
    $self->_render_template($c, \$output, $options);
    $content->{content} = $output
      if $content->{content} !~ /\S/ && $output =~ /\S/;
  }

  # Encoding
  $output = encode $options->{encoding}, $output
    if !$partial && $options->{encoding} && $output;

  return $output, $options->{format};
}

sub template_for {
  my ($self, $c) = @_;

  # Normal default template
  my $stash = $c->stash;
  my ($controller, $action) = @$stash{qw(controller action)};
  return join '/', split('-', decamelize($controller)), $action
    if $controller && $action;

  # Try the route name if we don't have controller and action
  return undef unless my $endpoint = $c->match->endpoint;
  return $endpoint->name;
}

sub template_handler {
  my ($self, $options) = @_;

  # Templates
  return undef unless my $file = $self->template_name($options);
  unless ($self->{templates}) {
    s/\.(\w+)$// and $self->{templates}{$_} ||= $1
      for map { sort @{Mojo::Home->new($_)->list_files} } @{$self->paths};
  }
  return $self->{templates}{$file} if exists $self->{templates}{$file};

  # DATA templates
  unless ($self->{data}) {
    my $loader = Mojo::Loader->new;
    my @templates = map { sort keys %{$loader->data($_)} } @{$self->classes};
    s/\.(\w+)$// and $self->{data}{$_} ||= $1 for @templates;
  }
  return $self->{data}{$file} if exists $self->{data}{$file};

  # Default
  return $self->default_handler;
}

sub template_name {
  my ($self, $options) = @_;
  return undef unless my $template = $options->{template};
  return undef unless my $format   = $options->{format};
  my $handler = $options->{handler};
  return defined $handler ? "$template.$format.$handler" : "$template.$format";
}

sub template_path {
  my $self = shift;

  # Nameless
  return undef unless my $name = $self->template_name(shift);

  # Search all paths
  for my $path (@{$self->paths}) {
    my $file = catfile($path, split '/', $name);
    return $file if -r $file;
  }

  # Fall back to first path
  return catfile($self->paths->[0], split '/', $name);
}

sub _add {
  my ($self, $attr, $name, $cb) = @_;
  $self->$attr->{$name} = $cb;
  return $self;
}

sub _bundled { $TEMPLATES{"@{[pop]}.html.ep"} }

sub _extends {
  my ($self, $stash) = @_;
  my $layout = delete $stash->{layout};
  $stash->{extends} ||= join('/', 'layouts', $layout) if $layout;
  return delete $stash->{extends};
}

sub _render_template {
  my ($self, $c, $output, $options) = @_;

  # Find handler and render
  my $handler = $options->{handler} ||= $self->template_handler($options);
  if (my $renderer = $self->handlers->{$handler}) {
    return 1 if $renderer->($self, $c, $output, $options);
  }

  # No handler
  else { $c->app->log->error(qq{No handler for "$handler" available.}) }
  return undef;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Renderer - Generate dynamic content

=head1 SYNOPSIS

  use Mojolicious::Renderer;

  my $renderer = Mojolicious::Renderer->new;
  push @{$renderer->classes}, 'MyApp::Foo';
  push @{renderer->paths}, '/home/sri/templates';

=head1 DESCRIPTION

L<Mojolicious::Renderer> is the standard L<Mojolicious> renderer.

See L<Mojolicious::Guides::Rendering> for more.

=head1 ATTRIBUTES

L<Mojolicious::Renderer> implements the following attributes.

=head2 cache

  my $cache = $renderer->cache;
  $renderer = $renderer->cache(Mojo::Cache->new);

Renderer cache, defaults to a L<Mojo::Cache> object.

=head2 classes

  my $classes = $renderer->classes;
  $renderer   = $renderer->classes(['main']);

Classes to use for finding templates in C<DATA> sections, first one has the
highest precedence, defaults to C<main>.

  # Add another class with templates in DATA section
  push @{$renderer->classes}, 'Mojolicious::Plugin::Fun';

=head2 default_format

  my $default = $renderer->default_format;
  $renderer   = $renderer->default_format('html');

The default format to render if C<format> is not set in the stash.

=head2 default_handler

  my $default = $renderer->default_handler;
  $renderer   = $renderer->default_handler('ep');

The default template handler to use for rendering in cases where auto
detection doesn't work, like for C<inline> templates.

=head2 encoding

  my $encoding = $renderer->encoding;
  $renderer    = $renderer->encoding('koi8-r');

Will encode generated content if set, defaults to C<UTF-8>. Note that many
renderers such as L<Mojolicious::Plugin::EPRenderer> also use this value to
determine if template files should be decoded before processing.

=head2 handlers

  my $handlers = $renderer->handlers;
  $renderer    = $renderer->handlers({epl => sub {...}});

Registered handlers, by default only C<data>, C<text> and C<json> are already
defined.

=head2 helpers

  my $helpers = $renderer->helpers;
  $renderer   = $renderer->helpers({url_for => sub {...}});

Registered helpers.

=head2 paths

  my $paths = $renderer->paths;
  $renderer = $renderer->paths(['/home/sri/templates']);

Directories to look for templates in, first one has the highest precedence.

  # Add another "templates" directory
  push @{$renderer->paths}, '/home/sri/templates';

=head1 METHODS

L<Mojolicious::Renderer> inherits all methods from L<Mojo::Base> and
implements the following new ones.

=head2 accepts

  my $all  = $renderer->accepts(Mojolicious::Controller->new);
  my $best = $renderer->accepts(Mojolicious::Controller->new, 'html', 'json');

Select best possible representation for L<Mojolicious::Controller> object from
C<Accept> request header, C<format> stash value or C<format> GET/POST
parameter, defaults to returning the first extension if no preference could be
detected. Since browsers often don't really know what they actually want,
unspecific C<Accept> request headers with more than one MIME type will be
ignored, unless the C<X-Requested-With> header is set to the value
C<XMLHttpRequest>.

=head2 add_handler

  $renderer = $renderer->add_handler(epl => sub {...});

Register a new handler.

=head2 add_helper

  $renderer = $renderer->add_helper(url_for => sub {...});

Register a new helper.

=head2 get_data_template

  my $template = $renderer->get_data_template({
    template       => 'foo/bar',
    format         => 'html',
    handler        => 'epl'
  });

Get a C<DATA> section template by name, usually used by handlers.

=head2 render

  my ($output, $format) = $renderer->render(Mojolicious::Controller->new);
  my ($output, $format) = $renderer->render(Mojolicious::Controller->new, {
    template => 'foo/bar',
    foo      => 'bar'
  });

Render output through one of the renderers. See
L<Mojolicious::Controller/"render"> for a more user-friendly interface.

=head2 template_for

  my $name = $renderer->template_for(Mojolicious::Controller->new);

Generate default template name for L<Mojolicious::Controller> object.

=head2 template_handler

  my $handler = $renderer->template_handler({
    template => 'foo/bar',
    format   => 'html'
  });

Detect handler based on an options hash reference with C<template> and
C<format>.

=head2 template_name

  my $template = $renderer->template_name({
    template => 'foo/bar',
    format   => 'html',
    handler  => 'epl'
  });

Builds a template name based on an options hash reference with C<template>,
C<format> and C<handler>, usually used by handlers.

=head2 template_path

  my $path = $renderer->template_path({
    template => 'foo/bar',
    format   => 'html',
    handler  => 'epl'
  });

Builds a full template path based on an options hash reference with
C<template>, C<format> and C<handler>, usually used by handlers.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
