package Catalyst::Dispatcher;

use Moose;
use Class::MOP;
with 'MooseX::Emulate::Class::Accessor::Fast';

use Catalyst::Exception;
use Catalyst::Utils;
use Catalyst::Action;
use Catalyst::ActionContainer;
use Catalyst::DispatchType::Default;
use Catalyst::DispatchType::Index;
use Catalyst::Utils;
use Text::SimpleTable;
use Tree::Simple;
use Tree::Simple::Visitor::FindByPath;

# Refactoring note:
# do these belong as package vars or should we build these via a builder method?
# See Catalyst-Plugin-Server for them being added to, which should be much less ugly.

# Preload these action types
our @PRELOAD = qw/Index Path Regex/;

# Postload these action types
our @POSTLOAD = qw/Default/;

# Note - see back-compat methods at end of file.
has _tree => (is => 'rw');
has _dispatch_types => (is => 'rw', default => sub { [] }, required => 1, lazy => 1);
has _registered_dispatch_types => (is => 'rw', default => sub { {} }, required => 1, lazy => 1);
has _method_action_class => (is => 'rw', default => 'Catalyst::Action');
has _action_hash => (is => 'rw', required => 1, lazy => 1, default => sub { {} });
has _container_hash => (is => 'rw', required => 1, lazy => 1, default => sub { {} });
has preload_dispatch_types => (is => 'rw', required => 1, lazy => 1, default => sub { [@PRELOAD] });

has postload_dispatch_types => (is => 'rw', required => 1, lazy => 1, default => sub { [@POSTLOAD] });

# Wrap accessors so you can assign a list and it will capture a list ref.
around qw/preload_dispatch_types postload_dispatch_types/ => sub {
    my $orig = shift;
    my $self = shift;
    return $self->$orig([@_]) if (scalar @_ && ref $_[0] ne 'ARRAY');
    return $self->$orig(@_);
};

no Moose;

=head1 NAME

Catalyst::Dispatcher - The Catalyst Dispatcher

=head1 SYNOPSIS

See L<Catalyst>.

=head1 DESCRIPTION

This is the class that maps public urls to actions in your Catalyst
application based on the attributes you set.

=head1 METHODS

=head2 new 

Construct a new dispatcher.

=cut

sub BUILD {
  my ($self, $params) = @_;

  my $container =
    Catalyst::ActionContainer->new( { part => '/', actions => {} } );

  $self->_tree( Tree::Simple->new( $container, Tree::Simple->ROOT ) );
}

=head2 $self->preload_dispatch_types

An arrayref of pre-loaded dispatchtype classes

Entries are considered to be available as C<Catalyst::DispatchType::CLASS>
To use a custom class outside the regular C<Catalyst> namespace, prefix
it with a C<+>, like so:

    +My::Dispatch::Type

=head2 $self->postload_dispatch_types

An arrayref of post-loaded dispatchtype classes

Entries are considered to be available as C<Catalyst::DispatchType::CLASS>
To use a custom class outside the regular C<Catalyst> namespace, prefix
it with a C<+>, like so:

    +My::Dispatch::Type

=head2 $self->dispatch($c)

Delegate the dispatch to the action that matched the url, or return a
message about unknown resource

=cut

sub dispatch {
    my ( $self, $c ) = @_;
    if ( my $action = $c->action ) {
        $c->forward( join( '/', '', $action->namespace, '_DISPATCH' ) );
    }
    else {
        my $path  = $c->req->path;
        my $error = $path
          ? qq/Unknown resource "$path"/
          : "No default action defined";
        $c->log->error($error) if $c->debug;
        $c->error($error);
    }
}

# $self->_command2action( $c, $command [, \@arguments ] )
# $self->_command2action( $c, $command [, \@captures, \@arguments ] )
# Search for an action, from the command and returns C<($action, $args, $captures)> on
# success. Returns C<(0)> on error.

sub _command2action {
    my ( $self, $c, $command, @extra_params ) = @_;

    unless ($command) {
        $c->log->debug('Nothing to go to') if $c->debug;
        return 0;
    }

    my (@args, @captures);

    if ( ref( $extra_params[-2] ) eq 'ARRAY' ) {
        @captures = @{ pop @extra_params };
    }

    if ( ref( $extra_params[-1] ) eq 'ARRAY' ) {
        @args = @{ pop @extra_params }
    } else {
        # this is a copy, it may take some abuse from
        # ->_invoke_as_path if the path had trailing parts
        @args = @{ $c->request->arguments };
    }

    my $action;

    # go to a string path ("/foo/bar/gorch")
    # or action object
    if (blessed($command) && $command->isa('Catalyst::Action')) {
        $action = $command;
    }
    else {
        $action = $self->_invoke_as_path( $c, "$command", \@args );
    }

    # go to a component ( "MyApp::*::Foo" or $c->component("...")
    # - a path or an object)
    unless ($action) {
        my $method = @extra_params ? $extra_params[0] : "process";
        $action = $self->_invoke_as_component( $c, $command, $method );
    }

    return $action, \@args, \@captures;
}

=head2 $self->visit( $c, $command [, \@arguments ] )

Documented in L<Catalyst>

=cut

sub visit {
    my $self = shift;
    $self->_do_visit('visit', @_);
}

sub _do_visit {
    my $self = shift;
    my $opname = shift;
    my ( $c, $command ) = @_;
    my ( $action, $args, $captures ) = $self->_command2action(@_);
    my $error = qq/Couldn't $opname("$command"): /;

    if (!$action) {
        $error .= qq/Couldn't $opname to command "$command": /
                 .qq/Invalid action or component./;
    }
    elsif (!defined $action->namespace) {
        $error .= qq/Action has no namespace: cannot $opname() to a plain /
                 .qq/method or component, must be a :Action or some sort./
    }
    elsif (!$action->class->can('_DISPATCH')) {
        $error .= qq/Action cannot _DISPATCH. /
                 .qq/Did you try to $opname() a non-controller action?/;
    }
    else {
        $error = q();
    }

    if($error) {
        $c->error($error);
        $c->log->debug($error) if $c->debug;
        return 0;
    }

    $action = $self->expand_action($action);

    local $c->request->{arguments} = $args;
    local $c->request->{captures}  = $captures;
    local $c->{namespace} = $action->{'namespace'};
    local $c->{action} = $action;

    $self->dispatch($c);
}

=head2 $self->go( $c, $command [, \@arguments ] )

Documented in L<Catalyst>

=cut

sub go {
    my $self = shift;
    $self->_do_visit('go', @_);
    die $Catalyst::GO;
}

=head2 $self->forward( $c, $command [, \@arguments ] )

Documented in L<Catalyst>

=cut

sub forward {
    my $self = shift;
    $self->_do_forward(forward => @_);
}

sub _do_forward {
    my $self = shift;
    my $opname = shift;
    my ( $c, $command ) = @_;
    my ( $action, $args, $captures ) = $self->_command2action(@_);

    if (!$action) {
        my $error .= qq/Couldn't $opname to command "$command": /
                    .qq/Invalid action or component./;
        $c->error($error);
        $c->log->debug($error) if $c->debug;
        return 0;
    }

    no warnings 'recursion';

    local $c->request->{arguments} = $args;
    $action->dispatch( $c );

    return $c->state;
}

=head2 $self->detach( $c, $command [, \@arguments ] )

Documented in L<Catalyst>

=cut

sub detach {
    my ( $self, $c, $command, @args ) = @_;
    $self->_do_forward(detach => $c, $command, @args ) if $command;
    die $Catalyst::DETACH;
}

sub _action_rel2abs {
    my ( $self, $c, $path ) = @_;

    unless ( $path =~ m#^/# ) {
        my $namespace = $c->stack->[-1]->namespace;
        $path = "$namespace/$path";
    }

    $path =~ s#^/##;
    return $path;
}

sub _invoke_as_path {
    my ( $self, $c, $rel_path, $args ) = @_;

    my $path = $self->_action_rel2abs( $c, $rel_path );

    my ( $tail, @extra_args );
    while ( ( $path, $tail ) = ( $path =~ m#^(?:(.*)/)?(\w+)?$# ) )
    {                           # allow $path to be empty
        if ( my $action = $c->get_action( $tail, $path ) ) {
            push @$args, @extra_args;
            return $action;
        }
        else {
            return
              unless $path
              ; # if a match on the global namespace failed then the whole lookup failed
        }

        unshift @extra_args, $tail;
    }
}

sub _find_component_class {
    my ( $self, $c, $component ) = @_;

    return ref($component)
      || ref( $c->component($component) )
      || $c->component($component);
}

sub _invoke_as_component {
    my ( $self, $c, $component, $method ) = @_;

    my $class = $self->_find_component_class( $c, $component ) || return 0;

    if ( my $code = $class->can($method) ) {
        return $self->_method_action_class->new(
            {
                name      => $method,
                code      => $code,
                reverse   => "$class->$method",
                class     => $class,
                namespace => Catalyst::Utils::class2prefix(
                    $class, $c->config->{case_sensitive}
                ),
            }
        );
    }
    else {
        my $error =
          qq/Couldn't forward to "$class". Does not implement "$method"/;
        $c->error($error);
        $c->log->debug($error)
          if $c->debug;
        return 0;
    }
}

=head2 $self->prepare_action($c)

Find an dispatch type that matches $c->req->path, and set args from it.

=cut

sub prepare_action {
    my ( $self, $c ) = @_;
    my $req = $c->req;
    my $path = $req->path;
    my @path = split /\//, $req->path;
    $req->args( \my @args );

    unshift( @path, '' );    # Root action

  DESCEND: while (@path) {
        $path = join '/', @path;
        $path =~ s#^/##;

        $path = '' if $path eq '/';    # Root action

        # Check out dispatch types to see if any will handle the path at
        # this level

        foreach my $type ( @{ $self->_dispatch_types } ) {
            last DESCEND if $type->match( $c, $path );
        }

        # If not, move the last part path to args
        my $arg = pop(@path);
        $arg =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        unshift @args, $arg;
    }

    s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg for grep { defined } @{$req->captures||[]};

    $c->log->debug( 'Path is "' . $req->match . '"' )
      if ( $c->debug && defined $req->match && length $req->match );

    $c->log->debug( 'Arguments are "' . join( '/', @args ) . '"' )
      if ( $c->debug && @args );
}

=head2 $self->get_action( $action, $namespace )

returns a named action from a given namespace.

=cut

sub get_action {
    my ( $self, $name, $namespace ) = @_;
    return unless $name;

    $namespace = join( "/", grep { length } split '/', ( defined $namespace ? $namespace : "" ) );

    return $self->_action_hash->{"${namespace}/${name}"};
}

=head2 $self->get_action_by_path( $path ); 

Returns the named action by its full path. 

=cut

sub get_action_by_path {
    my ( $self, $path ) = @_;
    $path =~ s/^\///;
    $path = "/$path" unless $path =~ /\//;
    $self->_action_hash->{$path};
}

=head2 $self->get_actions( $c, $action, $namespace )

=cut

sub get_actions {
    my ( $self, $c, $action, $namespace ) = @_;
    return [] unless $action;

    $namespace = join( "/", grep { length } split '/', $namespace || "" );

    my @match = $self->get_containers($namespace);

    return map { $_->get_action($action) } @match;
}

=head2 $self->get_containers( $namespace )

Return all the action containers for a given namespace, inclusive

=cut

sub get_containers {
    my ( $self, $namespace ) = @_;
    $namespace ||= '';
    $namespace = '' if $namespace eq '/';

    my @containers;

    if ( length $namespace ) {
        do {
            push @containers, $self->_container_hash->{$namespace};
        } while ( $namespace =~ s#/[^/]+$## );
    }

    return reverse grep { defined } @containers, $self->_container_hash->{''};

    #return (split '/', $namespace); # isnt this more clear?
    my @parts = split '/', $namespace;
}

=head2 $self->uri_for_action($action, \@captures)

Takes a Catalyst::Action object and action parameters and returns a URI
part such that if $c->req->path were this URI part, this action would be
dispatched to with $c->req->captures set to the supplied arrayref.

If the action object is not available for external dispatch or the dispatcher
cannot determine an appropriate URI, this method will return undef.

=cut

sub uri_for_action {
    my ( $self, $action, $captures) = @_;
    $captures ||= [];
    foreach my $dispatch_type ( @{ $self->_dispatch_types } ) {
        my $uri = $dispatch_type->uri_for_action( $action, $captures );
        return( $uri eq '' ? '/' : $uri )
            if defined($uri);
    }
    return undef;
}

=head2 expand_action

expand an action into a full representation of the dispatch.
mostly useful for chained, other actions will just return a
single action.

=cut

sub expand_action {
    my ($self, $action) = @_;

    foreach my $dispatch_type (@{ $self->_dispatch_types }) {
        my $expanded = $dispatch_type->expand_action($action);
        return $expanded if $expanded;
    }

    return $action;
}

=head2 $self->register( $c, $action )

Make sure all required dispatch types for this action are loaded, then
pass the action to our dispatch types so they can register it if required.
Also, set up the tree with the action containers.

=cut

sub register {
    my ( $self, $c, $action ) = @_;

    my $registered = $self->_registered_dispatch_types;

    #my $priv = 0; #seems to be unused
    foreach my $key ( keys %{ $action->attributes } ) {
        next if $key eq 'Private';
        my $class = "Catalyst::DispatchType::$key";
        unless ( $registered->{$class} ) {
            # FIXME - Some error checking and re-throwing needed here, as
            #         we eat exceptions loading dispatch types.
            eval { Class::MOP::load_class($class) };
            push( @{ $self->_dispatch_types }, $class->new ) unless $@;
            $registered->{$class} = 1;
        }
    }

    # Pass the action to our dispatch types so they can register it if reqd.
    foreach my $type ( @{ $self->_dispatch_types } ) {
        $type->register( $c, $action );
    }

    my $namespace = $action->namespace;
    my $name      = $action->name;

    my $container = $self->_find_or_create_action_container($namespace);

    # Set the method value
    $container->add_action($action);

    $self->_action_hash->{"$namespace/$name"} = $action;
    $self->_container_hash->{$namespace} = $container;
}

sub _find_or_create_action_container {
    my ( $self, $namespace ) = @_;

    my $tree ||= $self->_tree;

    return $tree->getNodeValue unless $namespace;

    my @namespace = split '/', $namespace;
    return $self->_find_or_create_namespace_node( $tree, @namespace )
      ->getNodeValue;
}

sub _find_or_create_namespace_node {
    my ( $self, $parent, $part, @namespace ) = @_;

    return $parent unless $part;

    my $child =
      ( grep { $_->getNodeValue->part eq $part } $parent->getAllChildren )[0];

    unless ($child) {
        my $container = Catalyst::ActionContainer->new($part);
        $parent->addChild( $child = Tree::Simple->new($container) );
    }

    $self->_find_or_create_namespace_node( $child, @namespace );
}

=head2 $self->setup_actions( $class, $context )

Loads all of the preload dispatch types, registers their actions and then
loads all of the postload dispatch types, and iterates over the tree of
actions, displaying the debug information if appropriate.

=cut

sub setup_actions {
    my ( $self, $c ) = @_;

    my @classes =
      $self->_load_dispatch_types( @{ $self->preload_dispatch_types } );
    @{ $self->_registered_dispatch_types }{@classes} = (1) x @classes;

    foreach my $comp ( values %{ $c->components } ) {
        $comp->register_actions($c) if $comp->can('register_actions');
    }

    $self->_load_dispatch_types( @{ $self->postload_dispatch_types } );

    return unless $c->debug;
    $self->_display_action_tables($c);
}

sub _display_action_tables {
    my ($self, $c) = @_;

    my $column_width = Catalyst::Utils::term_width() - 20 - 36 - 12;
    my $privates = Text::SimpleTable->new(
        [ 20, 'Private' ], [ 36, 'Class' ], [ $column_width, 'Method' ]
    );

    my $has_private = 0;
    my $walker = sub {
        my ( $walker, $parent, $prefix ) = @_;
        $prefix .= $parent->getNodeValue || '';
        $prefix .= '/' unless $prefix =~ /\/$/;
        my $node = $parent->getNodeValue->actions;

        for my $action ( keys %{$node} ) {
            my $action_obj = $node->{$action};
            next
              if ( ( $action =~ /^_.*/ )
                && ( !$c->config->{show_internal_actions} ) );
            $privates->row( "$prefix$action", $action_obj->class, $action );
            $has_private = 1;
        }

        $walker->( $walker, $_, $prefix ) for $parent->getAllChildren;
    };

    $walker->( $walker, $self->_tree, '' );
    $c->log->debug( "Loaded Private actions:\n" . $privates->draw . "\n" )
      if $has_private;

    # List all public actions
    $_->list($c) for @{ $self->_dispatch_types };
}

sub _load_dispatch_types {
    my ( $self, @types ) = @_;

    my @loaded;

    # Preload action types
    for my $type (@types) {
        my $class =
          ( $type =~ /^\+(.*)$/ ) ? $1 : "Catalyst::DispatchType::${type}";

        eval { Class::MOP::load_class($class) };
        Catalyst::Exception->throw( message => qq/Couldn't load "$class"/ )
          if $@;
        push @{ $self->_dispatch_types }, $class->new;

        push @loaded, $class;
    }

    return @loaded;
}

# Dont document this until someone else is happy with beaviour. Ash 2009/03/16
sub dispatch_type {
    my ($self, $name) = @_;

    unless ($name =~ s/^\+//) {
        $name = "Catalyst::DispatchType::" . $name;
    }

    for (@{ $self->_dispatch_types }) {
        return $_ if ref($_) eq $name;
    }
    return undef;
}

use Moose;

# 5.70 backwards compatibility hacks.

# Various plugins (e.g. Plugin::Server and Plugin::Authorization::ACL)
# need the methods here which *should* be private..

# However we can't really take them away until there is a sane API for
# building actions and configuring / introspecting the dispatcher.
# In 5.90, we should build that infrastructure, port the plugins which
# use it, and then take the crap below away.
# See also t/lib/TestApp/Plugin/AddDispatchTypes.pm

# Alias _method_name to method_name, add a before modifier to warn..
foreach my $public_method_name (qw/ 
        tree 
        dispatch_types 
        registered_dispatch_types 
        method_action_class  
        action_hash 
        container_hash
    /) {
    my $private_method_name = '_' . $public_method_name;
    my $meta = __PACKAGE__->meta; # Calling meta method here fine as we happen at compile time.
    $meta->add_method($public_method_name, $meta->get_method($private_method_name));
    {
        my %package_hash; # Only warn once per method, per package. These are infrequent enough that
                          # I haven't provided a way to disable them, patches welcome.
        $meta->add_before_method_modifier($public_method_name, sub {
            my $class = blessed(shift);
            $package_hash{$class}++ || do { 
                warn("Class $class is calling the deprecated method Catalyst::Dispatcher::$public_method_name,\n"
                    . "this will be removed in Catalyst 5.9X");
            };
        });
    }
}
# End 5.70 backwards compatibility hacks.

no Moose;
__PACKAGE__->meta->make_immutable;

=head2 meta

Provided by Moose

=head1 AUTHORS

Catalyst Contributors, see Catalyst.pm

=head1 COPYRIGHT

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
