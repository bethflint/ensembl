#
# Ensembl module for Bio::EnsEMBL::Mapper::RangeRegistry
#
#
# You may distribute this module under the same terms as perl itself

=head1 NAME

Bio::EnsEMBL::Mapper::RangeRegistry

=head1 SYNOPSIS

   use Bio::EnsEMBL::Mapper::RangeRegistry;

   $rr = Bio::EnsEMBL::Mapper::RangeRegistry->new();

   #get a fixed width chunk around the range of intereset
   #this will be used if any registration is actually necessary
   $chunk_start = ($start >> 20) << 20 + 1;
   $chunk_end   = (($end >> 20) + 1) << 20;

  #check if any registration is necessary for the range.
  #if it is register a large chunked area instead and return a listref
  #of unregistered areas that need to be loaded.
  if($pairs=$rr->check_and_register($id,$start,$end,$chunk_start,$chunk_end)) {
    foreach my $pair (@$pairs) {
      my ($pair_start, $pair_end) = @$pair;
      #fetch mappings for these regions from the assembly table and load them
      #into the mapper
      ...
    }
  } else {
    #the range ($start - $end) is already registered
    ...
  }


  #check if any registration is necessary
  #if it is register the region and return a listref of pairs that
  #need to be loaded.
  if($pairs = $rr->check_and_register($id, $start,$end)) {
  }


=head1 DESCRIPTION

This module maintains an internal list of registered regions and is used to
quickly ascertain if and what regions of a provided range need registration.

=head1 AUTHOR - Graham McVicker

=head1 CONTACT

This modules is part of the Ensembl project http://www.ensembl.org

Questions can be posted to the ensembl-dev mailing list:
ensembl-dev@ebi.ac.uk

=cut

use strict;

package Bio::EnsEMBL::Mapper::RangeRegistry;

use Bio::EnsEMBL::Utils::Exception qw(throw);


=head2 new

  Arg [1]    : none
  Example    : my $rr = Bio::EnsEMBL::Mapper::RangeRegistry->new();
  Description: Creates a new RangeRegistry object
  Returntype : Bio::EnsEMBL::Mapper::RangeRegistry
  Exceptions : none
  Caller     : AssemblyMapperAdaptor

=cut

sub new {
  my $caller = shift;
  my $class = ref($caller) || $caller;
  return bless {'registry' => {}}, $class;
}


=head2 check_and_register

  Arg [1]    : string $id
               The id of the range to be checked/registered (e.g. a sequenceid)
  Arg [2]    : int $start
               The start of the range to be checked
  Arg [3]    : int $end
               The end of the range to be checked
  Arg [4]    : (optional) int $rstart
               The start of the range to be registered
               if the checked range was not fully registered
  Arg [5]    : (optional) int $rend
               The end of the range to be registerd
               if the checked range was not fully registered
  Example    : $ranges=$rr->check_and_register('X',500,600, 1,1_000_000));
  Description: Checks the range registry to see if the entire range
               denoted by ($id : $start-$end) is already registered.  If
               it already is, then undef is returned.  If it is not then
               the range specified by $rstart and $rend is registered, and
               a list of regions that were required to completely register
               $rstart-$rend is returned.  If $rstart and $rend are not
               defined they default to $start and $end respectively.

               The reason there is a single call to do both the checking and
               registering is to reduce the overhead. Much of the work to
               check if a range is registered is the same as registering a
               region around that range.
  Returntype : undef or listref of [start,end] range pairs
  Exceptions : throw if rstart is greater than start
               throw if rend is less than end
               throw if end is less than start
               throw if id, start, or end are not defined
  Caller     : AssemblyMapperAdaptor

=cut

#"constants"
my $START = 0;
my $END   = 1;

sub check_and_register {
  my ($self, $id, $start, $end, $rstart,$rend) = @_;

  $rstart = $start if(!defined($rstart));
  $rend   = $end if(!defined($rend));

  #
  # Sanity checks
  #
  if(!defined($id) || !defined($start) || !defined($end)) {
    throw("ID, start, end arguments are required");
  }

  if($start > $end) {
    throw("start argument must be less than end argument");
  }

  if($rstart >$rend) {
    throw("rend argument must be less than end argument");
  }

  if($rstart > $start) {
    throw("rstart must be less than or equal to start");
  }

  if($rend < $end) {
    throw("rend must be greater than or equal to end");
  }

  my $reg  = $self->{'registry'};
  my $list = $reg->{$id} ||= [];

  my @gap_pairs;

  my $rstart_idx = undef;
  my $i;

  my $len = scalar(@$list);

  if($len == 0) {
    #this is the first request for this id, return a gap pair for the
    #entire range and register it as seen
    $list->[0] = [$rstart,$rend];
    return [[$rstart,$rend]];
  }

  my $CUR;
  my $PREV;

  #####
  #loop through the list of existing ranges recording any "gaps" where the
  #existing range does not cover part of the requested range
  #
  for($CUR=0; $CUR < $len; $CUR++) {
    my $PREV = $CUR-1;
    my ($pstart,$pend) = @{$list->[$CUR]};

    #no work needs to be done at all if
    #if we find a range pair that entirely overlaps the requested region
    if($pstart <= $start && $pend >= $end) {
      return undef;
    }

    #record the index of the first pair that is within the range to be
    #registered
    #subtract one from the range start so that we can detect any
    #adjacent ranges that will need to be merged
    if(!defined($rstart_idx) && $pend >= ($rstart-1)) {
      $rstart_idx = $CUR;

      if($CUR == 0 && $pstart < $rend && $pstart > $rstart) {
	#need to add a gap at the very beginning because this is the first
	#range and is overlapped by requested range
	push @gap_pairs, [$rstart,$pstart-1];
      }
    }

    if($rend < $pstart) {
      #this range pair is past the end of the requested region
      #add a gap range up till the end of the requested range and stop
      #searching
      if($CUR > 0) {
        my $gap_start = $list->[$PREV]->[$END] + 1;
        push @gap_pairs, [$gap_start,$rend];
      } else {
	#the requested range is on its own at the beginning of the list
        push @gap_pairs, [$rstart,$rend];
      }
      last;
    }

    #record any gaps between registered ranges that we pass by on the way
    if(defined($rstart_idx) && $CUR > 0) {
      my $gap_start = $list->[$PREV]->[$END] + 1;
      my $gap_end   = $list->[$CUR]->[$START] - 1;
      push @gap_pairs, [$gap_start, $gap_end];
    }

    if($rend <= $pend) {
      #this range pair overlaps the end of the requested region
      last;
    }
  }

  #if we went right to the very end set the 'current' range to the
  #last existing range
  $CUR-- if($CUR == $len);

  #now check if another gap range pair needs to be added to the end of the list
  #whice will occur if the requested range extends past the last range in the
  if($list->[$CUR]->[$END] < $rend) {
    if($rstart < $list->[$CUR]->[$END]) {
      #this range overlaps with last seen exising range
      push @gap_pairs, [$list->[$CUR]->[$END]+1, $rend];
    } else {
      #this range is fully outside of the last seen exising range
      push @gap_pairs, [$rstart, $rend];
    }
  }

  my $last_range = $list->[$CUR];

  #####
  # Add the requested range to the list of ranges merging with the
  # existing ranges as necessary
  #
  if(!defined($rstart_idx)) {
    #this range is on its own at the end of the list;
    push @$list, [$rstart,$rend];
  } elsif($CUR == 0 && $last_range->[$START] > ($rend+1)) {
    #this range is on its own at the beginning of the list
    unshift @$list, [$rstart,$rend];
  } else {
    #this range overlaps or is adjacent to some of the existing ranges
    #we need to splice in a single new node into the list
    #to do this we just need to figure out the start and end values of the
    #node and where it should go
    my($new_start, $new_end, $rend_idx);

    if($list->[$rstart_idx]->[$START] > $rstart) {
      #the requested range fully covers the first existing overlapped range
      $new_start = $rstart;
    } else {
      #the requested range partially overlaps the existing range
      $new_start = $list->[$rstart_idx]->[$START];
    }

    #add one to check for adjacent ranges
    if($last_range->[$START] <= ($rend+1)) {
      if($last_range->[$END] < $rend) {
        #requested range extends past end of existing range
        $new_end = $rend;
        $rend_idx = $CUR+1;
      } else {
        #end of requested range is encompassed by or adjacent to existing range
        $new_end = $last_range->[$END];
        $rend_idx = $CUR;
      }
    } else {
      #end of requested range is before last examined region of existing range
      $rend_idx = $CUR-1;
      $new_end = $rend;
    }

    #perform the splice of the new range into the list
    my $splice_length = $rend_idx - $rstart_idx + 1;
    my $new_range = [$new_start,$new_end];
    splice(@$list, $rstart_idx, $splice_length,$new_range);
  }

  return \@gap_pairs;
}


1;

