#!/usr/bin/perl
#
# $Id: ASN.pm 590 2008-12-12 15:27:07Z calle $
#
# Copyright (c) 2007 .SE (The Internet Infrastructure Foundation).
#                    All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
# IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
######################################################################

package DNSCheck::Lookup::Resolver;

require 5.008;
use warnings;
use strict;

use YAML;
use Net::IP;

# In order to be able to know for sure where certain information comes from,
# and/or modify parts of resolver chains, we need to do our own recursive
# lookups rather than rely on an external caching recursive resolver. This
# module is supposed to do recursive lookups. It seems to work, but was
# written by someone who is not a DNS expert, so comments on the module logic
# is very welcome.
sub new {
    my $proto  = shift;
    my $parent = shift;
    my $class  = ref($proto) || $proto;
    my $self   = {};

    bless $self, $proto;

    $self->{parent} = $parent;

    $self->logger->auto("RESOLVER:CREATED");

    my $config = $self->config->get("dns");

    $self->{cache} = Load(join('', <DATA>));

    $self->{resolver} = Net::DNS::Resolver->new;
    $self->{resolver}->persistent_tcp(0);
    $self->{resolver}->cdflag(1);
    $self->{resolver}->recurse(0);
    $self->{resolver}->dnssec(0);
    $self->{resolver}->debug($config->{debug});
    $self->{resolver}->udp_timeout($config->{udp_timeout});
    $self->{resolver}->tcp_timeout($config->{tcp_timeout});
    $self->{resolver}->retry($config->{retry});
    $self->{resolver}->retrans($config->{retrans});

    return $self;
}

# Standard utility methods
sub resolver {
    return $_[0]->{resolver};
}

sub parent {
    return $_[0]->{parent};
}

sub cache {
    return $_[0]->{cache};
}

sub config {
    return $_[0]->parent->config;
}

sub logger {
    return $_[0]->parent->logger;
}

# Interface methods to underlying Net::DNS::Resolver object

sub errorstring {
    my $self = shift;

    return $self->resolver->errorstring(@_);
}

sub dnssec {
    my $self = shift;

    return $self->resolver->dnssec(@_);
}

# Add stuff to our cache.
#
# We cache known nameserver lists for names, and IP addresses for names.
sub remember {
    my ($self, $p, $name, $type, $class) = @_;

    return unless defined($p);

    foreach my $rr ($p->answer, $p->additional, $p->authority) {
        my $n = $self->canonicalize_name($rr->name);
        if ($rr->type eq 'A' or $rr->type eq 'AAAA') {
            push @{ $self->{cache}{ips}{$n} }, $rr->address;
            $self->logger->auto(
                sprintf("RESOLVER:CACHED_IP %s %s", $n, $rr->address));
        }
        if ($rr->type eq 'NS') {
            push @{ $self->{cache}{ns}{$n} },
              $self->canonicalize_name($rr->nsdname);
            $self->logger->auto(
                sprintf("RESOLVER:CACHED_NS %s %s", $n, $rr->nsdname));
        }
    }
}

# Reformat a name into a standardized form, for ease of comparison
sub canonicalize_name {
    my $self = shift;
    my $name = shift;

    $name = lc($name);

    if (my $i = Net::IP->new($name)) {
        $name = $i->reverse_ip;
    }

    $name .= '.' unless substr($name, -1) eq '.';

    return $name;
}

# Strip the leftmost label off a DNS name. If there are no labels left after
# removing one, returns a single period for the root level.
sub strip_label {
    my $self = shift;
    my $name = shift;

    my @labels = split /\./, $name;
    shift @labels;

    if (@labels) {
        return $self->canonicalize_name(join '.', @labels);
    } else {
        return '.';
    }
}

# Take a name, and return the nameserver names for the highest parent level we
# have in cache. Which, at worst, will be the root zone, the data for which we
# have hardcoded into the module.
sub highest_known_ns {
    my $self = shift;
    my $name = shift;

    while ($name ne '.') {
        return @{ $self->{cache}{ns}{$name} } if $self->{cache}{ns}{$name};
        $name = $self->strip_label($name);
    }

    return grep { $_ }
      map { $self->{cache}{ips}{$_} and @{ $self->{cache}{ips}{$_} } }
      @{ $self->{cache}{ns}{'.'} };
}

# Send a query to a specified set of nameservers and return the result.
sub get {
    my $self  = shift;
    my $name  = shift;
    my $type  = shift || 'NS';
    my $class = shift || 'IN';
    my @ns    = @_;

    $self->logger->auto("RESOLVER:GET $name $type $class @ns");
    my @ns_old = $self->{resolver}->nameservers;
    $self->{resolver}->nameservers(@ns) if @ns;

    my $p = $self->{resolver}->send($name, $class, $type);
    $self->remember($p, $name, $type, $class) if defined($p);

    $self->{resolver}->nameservers(@ns_old);
    return $p;
}

# Recursively look up stuff.
sub recurse {
    my $self  = shift;
    my $name  = shift;
    my $type  = shift || 'NS';
    my $class = shift || 'IN';

    my $done = undef;

    $name = $self->canonicalize_name($name);

    $self->logger->auto("RESOLVER:RECURSE $name $type $class");
    my $p = $self->get($name, $type, $class, $self->highest_known_ns($name));
    my $h = $p->header;

    return unless defined($p);
  TOP:

    until ($done) {

        if ($h->rcode ne 'NOERROR') {
            return $p;
        } elsif ($h->ancount > 0) {    # An actual answer
            $done = 1;
        } elsif ($h->nscount > 0) {    # Authority records
            my @ns;
            foreach my $rr ($p->authority) {
                if ($rr->type eq 'NS') {
                    my $n = $self->canonicalize_name($rr->nsdname);
                    if (my $ip = $self->{cache}{ips}{$n}) {
                        push @ns, @$ip;
                    } else {
                        $self->recurse($n, 'A');
                        redo TOP;
                    }
                } elsif ($rr->type eq 'SOA') {
                    $done = 1;
                }
            }
            $p = $self->get($name, $type, $class, @ns);
            return unless defined($p);
            $h = $p->header;
        }
    }

    return $p;
}

__DATA__
---
ips:
  a.root-servers.net.:
    - 198.41.0.4
    - 2001:503:ba3e:0:0:0:2:30
  b.root-servers.net.:
    - 192.228.79.201
  c.root-servers.net.:
    - 192.33.4.12
  d.root-servers.net.:
    - 128.8.10.90
  e.root-servers.net.:
    - 192.203.230.10
  f.root-servers.net.:
    - 192.5.5.241
    - 2001:500:2f:0:0:0:0:f
  g.root-servers.net.:
    - 192.112.36.4
  h.root-servers.net.:
    - 128.63.2.53
    - 2001:500:1:0:0:0:803f:235
  i.root-servers.net.:
    - 192.36.148.17
  j.root-servers.net.:
    - 192.58.128.30
    - 2001:503:c27:0:0:0:2:30
ns:
  .:
    - i.root-servers.net.
    - j.root-servers.net.
    - k.root-servers.net.
    - l.root-servers.net.
    - m.root-servers.net.
    - a.root-servers.net.
    - b.root-servers.net.
    - c.root-servers.net.
    - d.root-servers.net.
    - e.root-servers.net.
    - f.root-servers.net.
    - g.root-servers.net.
    - h.root-servers.net.
