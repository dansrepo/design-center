package DCAPI;

use strict;
use warnings;

use JSON;
use File::Which;
use File::Basename;

use DCAPI::Repo;

use constant API_VERSION => '0.0.1';
use constant CODER => JSON->new()->relaxed()->utf8()->allow_nonref();
use constant CAN_CODER => JSON->new()->canonical()->utf8()->allow_nonref();

use Mo qw/build default builder coerce is required/;

# has name2 => ( builder => 'name_builder' );
# has name4 => ( required => 1 );

has version => ( is => 'ro', default => sub { API_VERSION } );

has config => ( );

has curl => ( is => 'ro', default => sub { which('curl') } );
has repos => ( is => 'ro', default => sub { [] } );
has recognized_sources => ( is => 'ro', default => sub { [] } );
has warnings => ( is => 'ro', default => sub { {} } );

has coder =>
 (
  is => 'ro',
  default => sub { CODER },
 );

has canonical_coder =>
 (
  is => 'ro',
  default => sub { CAN_CODER },
 );

sub set_config
{
 my $self = shift @_;
 my $file = shift @_;

 $self->config($self->load($file));

 my @sources = @{(Util::hashref_search($self->config(), qw/recognized_sources/) || [])};
 $self->log5("Adding recognized source $_") foreach @sources;
 push @{$self->recognized_sources()}, @sources;

 my @repos = @{(Util::hashref_search($self->config(), qw/repolist/) || [])};
 $self->log5("Adding recognized repo $_") foreach @repos;
 push @{$self->repos()}, @repos;

 foreach my $location (@{$self->repos()}, @{$self->recognized_sources()})
 {
  next unless Util::is_resource_local($location);

  eval
  {
   $self->load_repo($location);
  };

  if ($@)
  {
   push @{$self->warnings()->{$location}}, $@;
  }
 }

 my $w = $self->warnings();
 return scalar keys %$w ? (1,  $w) : (1);
}

# note it's not "our" but "my"
my %repos;
sub load_repo
{
 my $self = shift;
 my $repo = shift;

 unless (exists $repos{$repo})
 {
  $repos{$repo} = DCAPI::Repo->new(api => $self,
                                   location => glob($repo));
 }

 return $repos{$repo};
}

sub data_dump
{
 my $self = shift;
 return
 {
  version => $self->version(),
  config => $self->config(),
  curl => $self->curl(),
  warnings => $self->warnings(),
  repolist => $self->repos(),
  recognized_sources => $self->recognized_sources(),
 };
}

sub search
{
 my $self = shift;
 return $self->list_int($self->recognized_sources(), @_);
}

sub list
{
 my $self = shift;
 return $self->list_int($self->repos(), @_);
}

sub list_int
{
 my $self = shift;
 my $repos = shift;
 my $term_data = shift;

 my %ret;
 foreach my $location (@$repos)
 {
  $self->log("Searching location %s for terms %s",
            $location,
            $term_data);
  my $repo = $self->load_repo($location);
  my @list = map { $_->name() } $repo->list($term_data);
  $ret{$repo->location()} = [ @list ];
 }

 return \%ret;
}

sub log_mode
{
 my $self = shift @_;
 return Util::hashref_search($self->config(), qw/log/);
}

sub log_level
{
 my $self = shift @_;
 return 0+Util::hashref_search($self->config(), qw/log_level/);
}

sub log
{
 my $self = shift @_;
 return $self->log_int(1, @_);
}

sub log2
{
 my $self = shift @_;
 return $self->log_int(2, @_);
}

sub log3
{
 my $self = shift @_;
 return $self->log_int(3, @_);
}

sub log4
{
 my $self = shift @_;
 return $self->log_int(4, @_);
}

sub log5
{
 my $self = shift @_;
 return $self->log_int(5, @_);
}

sub log_int
{
 my $self = shift @_;
 my $log_level = shift @_;

 # only recognize one log mode for now
 return unless $self->log_mode() eq 'STDERR';
 return unless $self->log_level() > $log_level;

 my $prefix;
 foreach my $level (1..4) # probe up to 4 levels to find the real caller
 {
  my ($package, $filename, $line, $subroutine, $hasargs, $wantarray,
     $evaltext, $is_require, $hints, $bitmask, $hinthash) = caller($level);

  $prefix = sprintf ('%s(%s:%s): ', $subroutine, basename($filename), $line);
  last unless $subroutine eq '(eval)';
 }

 my @plist;
 foreach (@_)
 {
  if (ref $_ eq 'ARRAY' || ref $_ eq 'HASH')
  {
   # we want to log it anyhow
   eval { push @plist, $self->encode($_) };
  }
  else
  {
   push @plist, $_;
  }
 }

 print STDERR $prefix;
 printf STDERR @plist;
 print STDERR "\n";
};

sub decode { shift; CODER->decode(@_) };
sub encode { shift; CODER->encode(@_) };
sub cencode { shift; CAN_CODER->encode(@_) };

sub dump_encode { shift; use Data::Dumper; return Dumper([@_]); }

sub curl_GET { shift->curl('GET', @_) };

sub curl
{
 my $self = shift @_;
 my $mode = shift @_;
 my $url = shift @_;

 my $curl = $self->curl();

 my $run = <<EOHIPPUS;
$curl -s $mode $url |
EOHIPPUS

 $self->log("Running: $run\n");

 open my $c, $run or return (undef, "Could not run command [$run]: $!");

 return ([<$c>], undef);
};

sub load_raw
{
 my $self = shift @_;
 my $f    = shift @_;
 return $self->load_int($f, 1);
}

sub load
{
 my $self = shift @_;
 my $f    = shift @_;
 return $self->load_int($f, 0);
}

sub load_int
{
 my $self = shift @_;
 my $f    = shift @_;
 my $raw  = shift @_;

 my @j;

 my $try_eval;
 eval
 {
  $try_eval = $self->decode($f);
 };

 if ($try_eval) # detect inline content, must be proper JSON
 {
  return ($try_eval);
 }
 elsif (Util::is_resource_local($f))
 {
  my $j;
  unless (open($j, '<', $f) && $j)
  {
   return (undef, "Could not inspect $f: $!");
  }

  @j = <$j>;
 }
 else
 {
  my ($j, $error) = $self->curl_GET($f);

  defined $error and return (undef, $error);
  defined $j or return (undef, "Unable to retrieve $f");

  @j = @$j;
 }

 if (scalar @j)
 {
  chomp @j;
  s/\n//g foreach @j;
  s/^\s*(#|\/\/).*//g foreach @j;

  if ($raw)
  {
   return (\@j);
  }
  else
  {
   return ($self->decode(join '', @j));
  }
 }

 return (undef, "No data was loaded from $f");
}

sub ok
{
 my $self = shift;
 print $self->encode($self->make_ok(@_)), "\n";
}

sub exit_error
{
 shift->error(@_);
 exit 0;
}

sub error
{
 my $self = shift;
 print $self->encode($self->make_error(@_)), "\n";
}

sub make_ok
{
 my $self = shift;
 my $ok = shift;
 $ok->{success} = JSON::true;
 $ok->{errors} ||= [];
 $ok->{warnings} ||= [];
 $ok->{log} ||= [];
 return { api_ok => $ok };
}

sub make_not_ok
{
 my $self = shift;
 my $nok = shift;
 $nok->{success} = JSON::false;
 $nok->{errors} ||= shift @_;
 $nok->{warnings} ||= shift @_;
 $nok->{log} ||= shift @_;
 return { api_not_ok => $nok };
}

sub make_error
{
 my $self = shift;
 return { api_error => [@_] };
}

1;
