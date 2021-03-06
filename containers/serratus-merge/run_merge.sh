#!/bin/bash
# run_merge
#
# Base: serratus-Aligner (>0.1)
# AMI : ami-059b454759561d9f4
# login: ec2-user@<ipv4>
# base: 9 Gb
#
set -eu
PIPE_VERSION="0.1.4"

function usage {
  echo ""
  echo "Usage: run_merge.sh -b <bam-block regex> -M '<samtools merge args>' [OPTIONS]"
  echo ""
  echo "    -h    Show this help/usage message"
  echo ""
  echo "    Required Parameters"
  echo "    -s    SRA Accession / output name"
  echo ""
  echo "    Merge Parameters"
  echo "    -b    A regex string which matches the prefix the bam-block files in"
  echo"           working in base directory [ *.bam ]"
  echo "          i.e."
  echo "          if merging SRR1337.001.bam, SRR1337.002.bam, ... , SRR1337.666.bam"
  echo "          then  [-b 'SRR1337*'] or  [-b 'SRR*'] will both work"
  echo "    -n    parallel CPU threads to use where applicable  [1]"
  echo ""
  echo "    Optional outputs"
  echo "    -i    Flag. Generate bam.bai index file. Requires sort, otherwise false."
  echo "    -f    Flag. Generate flagstat summary file"
  echo "    -r    Flag. Sort final bam output (requires double disk usage)"
  echo ""
  echo "    Arguments as string to pass to `samtools merge` command"
  echo "    -M    String of arguments"
  echo ""
  echo "    Output options"
  echo "    -d    Work directory in container with bam-block [pwd]"
  echo "    -o    <output_filename_prefix> [Defaults to SRA_ACCESSION]"
  echo ""
  echo "    Outputs a sorted Uploaded to s3: "
  echo "          <output_prefix>.bam, <output_prefix>.bam.bai, <output_prefix>.flagstat"
  echo ""
  echo "ex: bash run_merge.sh -b 'SRR*' -M '-l 9'"
  exit 1
}


# PARSE INPUT =============================================
# Generate random alpha-numeric for run-id
#RUNID=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1 )

# Run Parameters
BAMREGEX='*.bam'
SRA=''

# Merge Options
THREADS='1'
INDEX='negative'
FLAGSTAT='negative'
SORT='negative'

# Script Arguments -M
MERGE_ARGS=''

# Output options -do
BASEDIR="/home/serratus"
OUTNAME="$SRA"

while getopts b:s:nifrM:d:o:h FLAG; do
  case $FLAG in
    # Scheduler Options -----
    u)
      SCHED=$OPTARG
      ;;
    k)
      S3_BUCKET=$OPTARG
      ;;
    # Merge Options ---------
    n)
      THREADS=$OPTARG
      ;;
    i)
      INDEX="true"
      ;;
    f)
      FLAGSTAT="true"
      ;;
    r)
      SORT="true"
      ;;
    # Manual Overwrite ------
    s)
      SRA=$OPTARG
      ;;
    g)
      GENOME=$OPTARG
      ;;
    b)
      S3_BAMS=$OPTARG
      ;;
    w)
      AWS_CONFIG='TRUE'
      ;;
    # SCRIPT ARGUMENTS -------
    A)
      ALIGN_ARGS=$OPTARG
      ;;
    U)
      UL_ARGS='TRUE'
      ;;
    # output options -------
    d)
      BASEDIR=$OPTARG
      ;;
    o)
      OUTNAME=$OPTARG
      ;;
    h)  #show help ----------
      usage
      ;;
    \?) #unrecognized option - show help
      echo "Input parameter not recognized"
      usage
      ;;
  esac
done
shift $((OPTIND-1))

# Check inputs --------------
# Required parameters
if [ -z "$SRA" ]
then
  echo "-s <SRA / Outname> required"
  usage
fi


# MERGE ===================================================
# Final Output Bam File name
OUTBAM="$SRA.bam"

# Command to run summarizer script
summarizer="python3 /home/serratus/serratus_summarizer.py /dev/stdin $SRA.summary /dev/stdout"

# Create tmp list of bam files to merge
ls $BAMREGEX > bam.list


if [[ "$SORT" = true ]]
then
  # GENERATE SORTED BAM OUTPUT
  # Requires high disk usage for tmp files
  # Uses header from first bam entry

  # Extract header from first file
  samtools view -H $(head -n1 bam.list) > 0.header.sam

  # Initial merge gives un-sorted; with ugly header
  samtools merge -n -@ $THREADS -b bam.list -f /dev/stdout | \
  samtools view -h - | \
  $summarizer | \
  samtools sort -@ $THREADS - | \
  samtools reheader 0.header.sam - >\
  $OUTBAM

  if [[ "$INDEX" = true ]]
  then
    samtools index $OUTBAM
  fi

else
  # GENERATE REDUCED SIZE, UNSORTED BAM [DEFAULT]
  # Create Reduced SAM Header
  # (Only for non-sort option)

  # Extract header from first file
  #samtools view -H $(head -n1 bam.list) |
  #sed '/^@SQ/d' - > header.sam
  samtools view -H $(head -n1 bam.list) > header.sam

  # Insert dummy SQ to make file 'intact'
  #sed -i "1a\
#@SQ\tSN:serratus\tLN:1337
  #" header.sam

  #echo -e "@CO\t====SERRATUS.IO====" >> header.sam
  #echo -e "@CO\tThis sam header is modified to reduce filesize." >> header.sam
  #echo -e "@CO\tTo reconstitute the missing @SQ entries" >> header.sam
  #echo -e "@CO\tDownload the header this pan-genome (i.e. cov2r) from:" >> header.sam
  #echo -e "@CO\t  https://serratus-public.s3.amazonaws.com/seq/<GENOME>/dummy_header.sam" >> header.sam

  # Convert new header to bam (add EOF)
  #samtools view -b header.sam > header.bam

  # Created concatenated bam file w/ reduced header
  samtools cat --threads $THREADS \
    -b bam.list --no-PG |\
    samtools view -h - |\
    $summarizer | \
    samtools view -b - |\
    samtools reheader -P header.sam - \
    > $OUTBAM
  
fi

if [[ "$FLAGSTAT" = true ]]
then
  samtools flagstat $OUTBAM > $SRA.flagstat
  #cat $SRA.flagstat
  #echo ''
fi


# end of script