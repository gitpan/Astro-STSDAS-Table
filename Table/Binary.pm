package Astro::STSDAS::Table::Binary;

our $VERSION = '0.12';

use strict;
use warnings;
use FileHandle;
use Carp qw( carp croak );


our @ISA = qw( Astro::STSDAS::Table::Base );

use Astro::STSDAS::Table::Base;
use Astro::STSDAS::Table::Constants;


# things read in from the table
our @hdr_fields = ( 
		   'nhp',	# number of header parameters
		   'nhp_a',	# number of header parameters allocated
		   'nrows',	# number of rows written to table
		   'nrows_a',	# number of rows allocated
		   'ncols',	# number of column descriptors in table
		   'ncols_a',	# number of column descriptors allocated
		   'row_used',	# size in CHAR_SZ of space used in row
		   'row_len',	# size in CHAR_SZ of row length
		   'ttype',	# type of table (row or column ordered)
		   'version',	# STSDAS software version number
		  );




 # row_len  - the row length, in bytes, for row-ordered tables
 # row_used - the actual length of the row in the file, in bytes, for
 #            row-ordered tables
 # nrows_a  - the number of rows allocated (in a column ordered table)
 # ttype    - the type of table (either TT_ROW_ORDER or TT_COL_ORDER)
 # version  - "table software version number" from STSDAS created tables
 # row      - the next record (zero based) to be read in
 # last_col_idx - index of the last column read, for column ordered tables
 # last_col - the last column read, for column ordered tables


sub new
{ 
  my $this = shift;
  my $class = ref($this) || $this;

  my $self = $class->SUPER::new();

  $self->{last_col_idx} = -1;
  $self->{last_col} = undef;
  $self->{row} = 0;

  bless $self, $class;
}


# _read_hdr

# _read_hdr is an internal routine which digests the binary table
# header.  besides stocking the table hash with the information, it
# converts lengths into bytes and creates a pack() compatible format
# for reading in rows.  It also initializes various things.

sub _read_hdr
{
  my $self = shift;

  my $buf;
  read( $self->{fh}, $buf, 12 * $TypeSize{TY_INT()} ) == 
    12 * $TypeSize{TY_INT()} or
    croak( "no data or error reading header\n");

  my %rawhdr;
  @rawhdr{@hdr_fields} = unpack( 'i10', $buf );

  # save a few of the values
  $self->{row_len}  = $rawhdr{row_len}  * CHAR_SZ;
  $self->{row_used} = $rawhdr{row_used} * CHAR_SZ;
  $self->{nrows}    = $rawhdr{nrows};
  $self->{nrows_a}  = $rawhdr{nrows_a};
  $self->{ttype}    = $rawhdr{ttype};
  $self->{version}  = $rawhdr{version};


  if ( $rawhdr{nhp} )
  {
    my $pars = $self->{pars};

    for my $i ( 1 .. $rawhdr{nhp} )
    {
      read( $self->{fh}, $buf, 80 ) == 80 or
	croak( "ran out of data reading header parameter $i\n" );

      my $name = unpack('A*', substr($buf, 0, 8));
      my $type = $HdrType{substr( $buf, 8, 1 )};
      ( my $value = substr( $buf, 9, 71 ) ) =~ s/\0.*//g;

      if ( $type eq TY_STRING )
      {
	$value =~ s/^'|'$//g;
      }

      $pars->add( $name, $value, undef, $type );
    }
  }

  if ( $rawhdr{nhp_a} > $rawhdr{nhp} )
  {
    my $i = 1;
    while ( $i++ <= $rawhdr{nhp_a} - $rawhdr{nhp} )
    {
      read( $self->{fh}, $buf, 80 ) == 80 or
	croak( "ran out of data reading padding header record $i\n" );
    }
  }

  for my $coln ( 1 .. $rawhdr{ncols} )
  {
    read( $self->{fh}, $buf, 16 * $TypeSize{TY_INT()} ) == 
      16 * $TypeSize{TY_INT()} or
      croak( "ran out of data reading column definition $coln\n" );

    my ( $idx, $offset, $space, $type ) = unpack( 'i4', $buf );

    my $nelem;
    ( my $name   = substr( $buf,  4 * $TypeSize{TY_INT()}, 20 ) ) =~ s/\0.*//g;
    ( my $units  = substr( $buf,  9 * $TypeSize{TY_INT()}, 20 ) ) =~ s/\0.*//g;
    ( my $format = substr( $buf, 14 * $TypeSize{TY_INT()},  8 ) ) =~ s/\0.*//g;


    # if type is negative, it's a string; $type also gives length
    if ( $type < 0 )
    {
      $type = TY_STRING;
      $nelem = -$type;
    }

    # nope.  get the length from the number of bytes in the
    # element
    else
    {
      $nelem = $space * CHAR_SZ / $TypeSize{$type};
    }

    my $col = $self->{cols}->add( $name, $units, $format, $idx, 
				  $offset * CHAR_SZ,
				  $type, $nelem );


    $self->{row_extract} .= $col->fmt;
  }

  if ( $rawhdr{ncols_a} > $rawhdr{ncols} )
  {
    my $i = 1;
    while ( $i++ <= $rawhdr{ncols_a} - $rawhdr{ncols} )
    {
      read( $self->{fh}, $buf, 16 * $TypeSize{TY_INT()} ) == 
	16 * $TypeSize{TY_INT()} or
	croak( "ran out of data reading padding column definition $i\n" );
    }
  }
}




sub is_row_order { $_[0]->{ttype} == TT_ROW_ORDER }
sub is_col_order { $_[0]->{ttype} == TT_COL_ORDER }

*read_table = \&read_table_row;

sub read_rows_hash
{
  my $self = shift;

  my @rows;
  $#rows = $self->{nrows} - 1;

  if ( $self->is_row_order )
  {
    my $idx = 0;
    my $row;
    $rows[$idx++] = $row 
      while ( $row = $self->read_row_row_hash );
  }

  else
  {
    1 while $self->read_col_row_hash( \@rows );
  }

  \@rows;
}

sub read_rows_array
{
  my $self = shift;

  my @rows;
  $#rows = $self->{nrows} - 1;

  if ( $self->is_row_order )
  {
    my $idx = 0;
    while ( my $row = $self->read_row_row_array )
    {
      $rows[$idx++] = $row;
    }
  }

  else
  {
    # pre extend row arrays.
    foreach my $idx ( 0..($self->{nrows}-1) )
    {
      my @row;
      $#row = $self->{ncols} - 1;
      $rows[$idx] = \@row;
    }
    1 while $self->read_col_row_array( \@rows );
  }

  \@rows;
}

sub read_cols_hash
{
  my $self = shift;

  my $cols_arr = $self->read_cols_array;

  my %cols;
  @cols{ map { lc $_ } $self->{cols}->names } = @{$cols_arr};

  \%cols;
}

sub read_cols_array
{
  my $self = shift;

  my @cols;

  if ( $self->is_row_order )
  {
    @cols = map { my @a; $#a = $self->{nrows} - 1; \@a }
                       1..($self->{cols}->ncols - 1);

    use integer;
    my $idx;
    while( my $row = $self->read_row_row_array )
    {
      $cols[$_][$idx] = $row->[$_] for 0..($self->{cols}->ncols-1);
      $idx++;
    }
  }

  else
  {
    my $data;
    push @cols, $data
      while ( $data = $self->read_col_col_array );
  }

  \@cols;
}

# read a column from a column oriented table into a row hash
sub read_col_row_hash
{
  my $self = shift;
  my $row = shift;

  my $data = $self->read_col_col_array;
  my $name = $self->{last_col}->name;

  eval qq{
    use integer;
    \$row->[\$_]{$name} = \$data->[\$_] 
      foreach 0..($self->{nrows}-1) ;
  };

  1;
}

# read a column from a column oriented table into a row array
sub read_col_row_array
{
  my $self = shift;
  my $row = shift;

  my $data = $self->read_col_col_array;

  eval qq{
    use integer;
    \$row->[\$_][$self->{last_col_idx}] =
      \$data->[\$_] foreach 0..($self->{nrows}-1) ;
  };
  1;
}

sub read_col_col_array
{
  my $self = shift;

  my $data = $self->_read_next_col;
  my $col = $self->{last_col};

  # if there are no vector elements, just return the data as is
  return $data if 1 == $col->{nelem};

  # deal with the vector elements
  my @vec_data;
  $#vec_data = $self->{nrows} - 1;

  use integer;
  my $dp = 0;
  for ( my $idx = 0; $idx < $self->{nrows} ; $idx++, $dp += $col->nelem )
  {
    $vec_data[$idx] = [ @{$data}[$dp .. ($dp + $col->nelem-1) ] ] ;
  }

  return \@vec_data;
}


sub _read_next_col
{
  my $self = shift;
  my $row = shift;

  # if we're all done, don't bother
  return () if $self->{last_col_idx} + 1 == $self->{cols}->ncols;

  my $buf;

  my $col = $self->{cols}->byidx($self->{last_col_idx} + 1);

  my $ndata = $self->{nrows_a} * $col->nelem;
  my $nbytes =  $ndata * $col->size;

  my $nread = read( $self->{fh}, $buf, $nbytes );

  unless( $nbytes == $nread )
  {
    # gotta be exactly $nbytes or we're loused
    croak( "incomplete read of column ", $self->{last_col_idx} + 2, "\n" )
  }

  my @data = unpack( $col->ifmt . $ndata , $buf );

  # clean the data;
  unless ( $col->is_string )
  {
    $col->is_indef($_) && ($_ = undef) foreach @data;
  }

  $self->{last_col_idx}++;
  $self->{last_col} = $col;

  \@data;
}


sub read_row_row_array
{
  my $self = shift;
  $self->_read_next_row;
}



sub read_row_row_hash
{
  my $self = shift;
  my $row = $self->_read_next_row;

  return undef unless $row;

  my %row;
  @row{ map { lc $_ } $self->{cols}->names } = @$row;
  return \%row;
}

# _read_row

# This reads the next row from a row-ordered table into an array, in the
# same order as that of the columns in the table.  Vector elements are
# stored as described above.  It returns the undefined value if there are
# no more data.

sub _read_next_row
{
  my $self = shift;

  # guess what? there's (possibly only sometimes) an extra row filled
  # with indefs at the end of the file! so we can't actually use
  # the end of file condition to stop reading.  ACKCKCKCCKKC!
  return undef if $self->{row} == $self->{nrows};


  my $buf;
  my $nread = read( $self->{fh}, $buf, $self->{row_len});

  unless( $nread == $self->{row_len} )
  {
    # if it's not zero, then we've read too little, and that's a no-no
    croak( "incomplete last record (", $self->{row}+1, ")\n" )
      if 0 != $nread;

    # EOF
    return undef;
  }

  my @data = unpack( $self->{row_extract}, $buf );

  # this is slow, but it works. clean it up someday
  my @row;
  for my $col ( $self->{cols}->idxs )
  {
    if ( $col->nelem == 1 )
    {
      my $data = shift @data;
      push @row, $col->is_indef($data) ? undef : $data;
    }
    else
    {
      push @row, 
         [ map { $col->is_indef($_) ? undef : $_ } 
	               splice( @data, 0, $col->nelem ) ];
    }
  }

  $self->{row}++;
  return \@row;
}


1;

__END__

=pod

=head1 NAME

Astro::STSDAS::Table::Binary - access a STSDAS binary format file

=head1 SYNOPSIS

  use Astro::STSDAS::Table::Binary;
  my $tbl = Astro::STSDAS::Table::Binary->new;
  $tbl->open( $file ) or die( "unable to open $file\n");

  if ( $tbl->is_row_order ) { ... }
  if ( $tbl->is_col_order ) { ... }

  # read an entire table:
  $rows = $tbl->read_rows_hash;
  # or
  $rows = $tbl->read_rows_array;
  # or
  $cols = $tbl->read_cols_hash;
  # or
  $cols = $tbl->read_cols_array;

  # read the next column from a column ordered table:
  $col = $tbl->read_col_col_array;
  # or
  $tbl->read_col_row_hash( \@rows );
  # or
  $tbl->read_col_row_array( \@rows );

  # read the next row from a row ordered table:
  $row = $tbl->read_row_row_array;
  # or
  $row = $tbl->read_row_row_hash;


=head1 DESCRIPTION

B<Astro::STSDAS::Table::Binary> provides access to STSDAS binary
format tables.  

STSDAS binary tables have some special properties:

=over 8

=item *

They may be in row (each "record" is a row) or column (each "record"
is a column) order.  This is handled by having different data read
routines for the different orders.  They are not entirely symmetric.

The easy way to deal with this is to simply read the entire table into
memory (provided it's small) with one of the B<read_rows_...> or
B<read_cols_...> routines.

=item *

Data elements may be vectors.  Vectors are represented in the
data as references to lists.  

=item *

Data values may be undefined.  Undefined values are converted to the
Perl undefined value.

=back

=head2 METHODS

B<Astro::STSDAS::Table::Binary> is derived from
B<Astro::STSDAS::Table::Base>, and thus inherits all of its methods.
Inherited methods are not necessarily documented below.

=over 8

=item new

  $self = Astro::STSDAS::Table::Binary->new;

The B<new> method is the class constructor, and must be called before
any other methods are invoked.

=item open

  $tbl->open( file or filehandle [, mode] );

B<open> connects to a file (if it is passed a scalar) or to an
existing file handle (if it is passed a reference to a glob).  If mode
is not specified, it is opened as read only, otherwise that specified.
Modes are the standard Perl-ish ones (see the Perl open command).  If
the mode is read only or read/write, it reads and parses the table
header.  It returns the undefined value upon error.

=item close

explicitly close the table.  This usually need not be called, as the
file will be closed when the object is destroyed.

=item read_rows_hash

  $rows = $tbl->read_rows_hash;

Digest the entire table.  This is called after B<open>. The table is
stored as an array of hashes, one hash per row.  The hash elements are
keyed off of the (lower cased) column names.

Vector elements are stored as references to arrays containing the
data.

For example, to access the value of column C<time> in row 3,

	$rows->[2]{time}

=item read_rows_array

  $rows = $tbl->read_rows_array;

Digest the entire table.  This is called after B<open>. The table is
stored as list of arrays, one array per row.

For example, to access the value of column 9 in row 3,

	$rows->[3][9]

=item read_cols_hash

  $cols = $tbl->read_cols_hash;

Digest the entire table.  This is called after B<open>.  The table is
stored as an hash, each element of which is a reference to an array
containing data for a column.  The hash keys are the (lower cased)
column names.  Vector elements are stored as references to arrays
containing the data.

For example, to access the value of column C<time> in row 3,

	$cols->{time}[2]

=item read_cols_array

  $cols = $tbl->read_cols_array;

Digest the entire table.  This is called after B<open>.  The table is
stored as an array, each element of which is a reference to an array
containing data for a column.  Vector elements are stored as
references to arrays containing the data.

For example, to access the value of column 9 in row 3,

	$cols->[9][3]

=item is_row_order

This method returns true if the table is stored in row order.

=item is_col_order

This method returns true if the table is stored in column order.

=item read_col_col_array

  $col = $tbl->read_col_col_array;

This reads the next column from a column ordered table into an array.
It returns a reference to the array containing the data.  Vector
elements are stored as references to arrays containing the data.

It returns undefined if it has reached the end of the data.


=item read_row_row_array

  $row = $tbl->read_row_row_array;

This reads the next row from a row-ordered table into an array, in the
same order as that of the columns in the table.  Vector elements are
stored as references to arrays containing the data.

It returns the undefined value if there are no more data.


=item read_row_row_hash

  $row = $tbl->read_row_row_hash

This reads the next row from a row-ordered table into a hash, keyed
off of the column names.  Vector elements are stored as references to
arrays containing the data.

It returns the undefined value if there are no more data.


=item read_col_row_hash

  $tbl->read_col_row_hash( \@rows) ;

This reads the next column from a column ordered table.  The data are
stored in an array of hashes, one hash per row, keyed off of the
column name.  The passed array ref is to that array of hashes.  Vector
elements are stored as references to arrays containing the data.

It returns undefined if it has reached the end of the data.

This routine is seldom (if ever) called by an application.


=item read_col_row_array

  $tbl->read_col_row_array( \@rows) ;

This reads the next column from a column ordered table.  The data are
stored in an array of arrays, one array per row.  The passed array ref
is to that array of arrays.  Vector elements are stored as references
to arrays containing the data.

It returns undefined if it has reached the end of the data.

This routine is seldom (if ever) called by an application.

=back

=head1 CAVEATS

=over 8

=item *

This class can only read, not write, tables.

=item *

Reading of column-ordered tables is untested.

=item *

Reading of tables with vector elements is untested.

=back

=head1 LICENSE

This software is released under the GNU General Public License.  You
may find a copy at 

   http://www.fsf.org/copyleft/gpl.html

=head1 AUTHOR

Diab Jerius ( djerius@cpan.org )

=cut

