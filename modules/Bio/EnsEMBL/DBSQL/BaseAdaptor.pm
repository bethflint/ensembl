
#
# BioPerl module for Bio::EnsEMBL::DBSQL::BaseAdaptor
#
# Cared for by Ewan Birney <birney@ebi.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::DBSQL::BaseAdaptor - Base Adaptor for DBSQL adaptors

=head1 SYNOPSIS

    # base adaptor provides
    
    # SQL prepare function
    $adaptor->prepare("sql statement");

    # get of root db object
    $adaptor->db();

    # delete memory cycles
    $adaptor->deleteObj();

    # constructor, ok for inheritence
    $adaptor = Bio::EnsEMBL::DBSQL::SubClassOfBaseAdaptor->new($dbobj)

=head1 DESCRIPTION

This is a true base class for Adaptors in the Ensembl DBSQL
system. Original idea from Arne


Adaptors are expected to have the following functions

    $obj = $adaptor->fetch_by_dbID($internal_id);

which builds the object from the primary key of the object. This
function is crucial because it allows adaptors to collaborate
relatively independently of each other - in other words, we can change
the schema under one adaptor without too many knock on changes through
the other adaptors.

Most adaptors will also have

    $dbid = $adaptor->store($obj);

which stores the object. Currently the storing of an object also causes
the objects to set

    $obj->dbID

correctly and attach the adaptor.


Other fetch functions go by the convention of

    @object_array = $adaptor->fetch_by_XXXX($arguments_for_XXXX)

sometimes it returns an array, sometimes an individual object depending on the
semantics to XXXX. For example

    $gene = $gene_adaptor->fetch_by_stable_id($stable_id);

or

    @fp  = $simple_feature_adaptor->fetch_by_contig($contig_internal_id);


Occassionally adaptors need to provide access to lists of ids. In this case the
convention is to go list_XXXX, such as

    @gene_ids = $gene_adaptor->list_geneIds();

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::DBSQL::BaseAdaptor;
use vars qw(@ISA);
use strict;
use Bio::EnsEMBL::Root;

@ISA = qw(Bio::EnsEMBL::Root);


=head2 new

  Arg [1]    : Bio::EnsEMBL::DBSQL::DBConnection $dbobj
  Example    : $adaptor = new AdaptorInheritedFromBaseAdaptor($dbobj);
  Description: Creates a new BaseAdaptor object.  The intent is that this
               constructor would be called by an inherited superclass either
               automatically or through $self->SUPER::new in an overridden 
               new method.
  Returntype : Bio::EnsEMBL::DBSQL::BaseAdaptor
  Exceptions : none
  Caller     : Bio::EnsEMBL::DBSQL::DBConnection

=cut

sub new {
    my ($class,$dbobj) = @_;

    my $self = {};
    bless $self,$class;

    if( !defined $dbobj || !ref $dbobj ) {
        $self->throw("Don't have a db [$dbobj] for new adaptor");
    }

    $self->db($dbobj);

    return $self;
}


=head2 prepare

  Arg [1]    : string $string
               a SQL query to be prepared by this adaptors database
  Example    : $sth = $adaptor->prepare("select yadda from blabla")
  Description: provides a DBI statement handle from the adaptor. A convenience
               function so you dont have to write $adaptor->db->prepare all the
               time
  Returntype : DBI::StatementHandle
  Exceptions : none
  Caller     : Adaptors inherited from BaseAdaptor

=cut

sub prepare{
   my ($self,$string) = @_;

   return $self->db->prepare($string);
}


=head2 db

  Arg [1]    : (optional) Bio::EnsEMBL::DBSQL::DBConnection $obj 
               the database this adaptor is using.
  Example    : $db = $adaptor->db();
  Description: Getter/Setter for the DatabaseConnection that this adaptor is 
               using.
  Returntype : Bio::EnsEMBL::DBSQL::DBConnection
  Exceptions : none
  Caller     : Adaptors inherited fro BaseAdaptor

=cut

sub db{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'db'} = $value;
    }
    return $obj->{'db'};

}


=head2 deleteObj

  Args       : none
  Example    : $adaptor->deleteObj();
  Description: Explicitly destroys this object and objects referenced by 
               this object.  This method should only be called if you know
               what you are doing, and is only needed for object destruction
               when circular references are present (these will prevent 
               perls automatic garbage collection).
  Returntype : none
  Exceptions : none
  Caller     : Bio::EnsEMBL::DBSQL::DBConnection?

=cut

sub deleteObj {
  my $self = shift;
  my @dummy = values %{$self};
  foreach my $key ( keys %$self ) {
    delete $self->{$key};
  }
  foreach my $obj ( @dummy ) {
    eval {
      $obj->deleteObj;
    }
  }
}


