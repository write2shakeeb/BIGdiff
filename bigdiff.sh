#!/bin/bash

# Author: Leonardo Souza
# Version: 1.0.0
# Date: 12/08/2018

# Version History - 1.0.0
# First Version

## Error Codes ##
# Script exit error codes

e_invalid_script_option=1
e_product_not_supported=2
e_software_verison_not_supported=3
e_no_snmp_community=4
e_running_snmpwalk=5
e_no_before_upgrade_file=6

## Variables ##
# No need to declare variables in Bash, but this is just to keep track

silent=0 # Indicates if script is running in silent mode
product="" # BIG-IP/BIG-IQ/etc..
supported_product=( BIG-IP ) # Produc supported by the script
supported_version=( 11 12 13 14 ) # List of versions the script supports
software_version="" # Software version used in the device
software_version_major="" # Major software version used in the device
script_name="BIGdiff" # Script name
script_author="" # Script author
script_version="" # Script version
script_date="" # Script date
message="" # Variable used for text in the dialog program
provision_gtm=0 # Indicates if GTM is provisioned
snmp_community="" # SNMP community
ltm_oids="" # LTM OIDs for snmpwalk
gtm_oids="" # GTM OIDs for snmpwalk
bug_364556_versions=( 11.0.0 11.1.0 11.2.0 11.2.1 11.3.0 ) # Versions affected by bug 364556 - https://support.f5.com/csp/article/K14618
before_file=${HOSTNAME}-before-`date "+%Y%m%d"`".txt" # Before upgrade file with snmpwalk output
after_file=${HOSTNAME}-after-`date "+%Y%m%d"`".txt" # After upgrade file with snmpwalk output
changes=0 # Number of changes found after upgrade
html_file=${HOSTNAME}-html-`date "+%Y%m%d"`".html" # HTML file generated by the script
html_tables_file=${HOSTNAME}-html-`date "+%Y%m%d"`".tmp" # Temporary HTML file to save the tables
temp_variable1="" # Temporary variable used in the script
temp_variable2="" # Temporary variable used in the script
temp_variable3="" # Temporary variable used in the script
index="" # Temporary variable used in the script
index2="" # Temporary variable used in the script
option="" # Temporary variable used in the script
exit_status="" # Temporary variable used in the script
# Multiple arrays to store objects
declare -a before_object_name
declare -a before_object_enabled
declare -a before_object_status
declare -a after_object_name
declare -a after_object_enabled
declare -a after_object_status
# Dialog exit Codes
dialog_cancel=1
dialog_esc=255

## General ##
# Diverse functions

# Disable standard output and standard error
silent_mode()
{
  silent=1
  # No output for the script
  exec &> /dev/null
}
# Populate variables with information about the script
script_information_variables()
{
  script_author=`egrep "^# Author:" $0`
  script_author=${script_author/"# Author: "}
  script_version=`egrep "^# Version:" $0`
  script_version=${script_version/"# Version: "}
  script_date=`egrep "^# Date:" $0`
  script_date=${script_date/"# Date: "}
}
# Output error to CLI and exit
cli_error()
{
  echo "Error: $1."
  exit $2
}
# Ouptut error using dialog and exit
menu_error()
{
  dialog --backtitle "$script_name - $HOSTNAME - $product $software_version" --title "Error" --msgbox "$1." 0 0
  exit $2
}
# If silent mode just exit, otherwise call menu_error
error()
{
  if [[ $silent == 1 ]]
  then
    exit $2
  else
    menu_error "$1" "$2"
  fi
}

## Checks ##
# Check that this script can run in this system

# Check if the system is a supported F5 product
check_product()
{
  if [[ -f "/VERSION" ]]
  then
    product=`fgrep Product /VERSION`
    product=${product/"Product: "}
    printf "%s \n" ${supported_product[@]} | grep $product &> /dev/null
    [[ $? != 0 ]] && cli_error "Product not supported" $e_product_not_supported
  else
    cli_error "Product not supported, not a F5 device" $e_product_not_supported
  fi
}
# Check if the system is running a version that is supported by this script
check_version()
{
  if [[ -f "/VERSION" ]]
  then
    software_version=`fgrep Version /VERSION`
    software_version=${software_version/"Version: "}
    software_version_major=${software_version%%.*}
    printf "%s \n" ${supported_version[@]} | grep $software_version_major &> /dev/null
    [[ $? != 0 ]] && cli_error "Software version not suppported" $e_software_verison_not_supported
  fi
}
# Check with modules a provisioned in the system
check_provision()
{
  # LTM Module
  # Most modules use LTM internally, so the script will show LTM even if it is not provisioned

  # GTM Module
  tmsh list sys provision gtm level 2> /dev/null | grep "level none" &> /dev/null
  [[ $? != 0 ]] && provision_gtm=1

  # Link Controller uses GTM Objects
  tmsh list sys provision lc level 2> /dev/null | grep "level none" &> /dev/null
  [[ $? != 0 ]] && provision_gtm=1
}

## Options ##
# Get script Options

# Provide information about how to run the script
usage()
{
  echo "Usage: `basename $0` -option"
  echo "If no option is provided, the script will run in menu mode."
  echo "If any option is provided, excepting h or e, the script will run in silent mode."
  echo "In silent mode, no menu is presented, no output is shown, and script error is indicated by script exit code."
  echo "Options:"
  echo "b - Run script before upgrade."
  echo "a - Run script after upgrade."
  echo "h - Print information about how to use the script."
  echo "e - Print information about error codes."
  echo "i - Script information."
  exit 0
}
# Output error code variables in the script code
error_codes()
{
  echo "Script exit error codes:"
  egrep "^e_" $0
  exit 0
}
# Output information about the script
script_information()
{
  echo "Author: $script_author"
  echo "Version: $script_version"
  echo "Date: $script_date"
}
# Option - Run script before upgrade
option_b()
{
  silent_mode
  get_snmp_community
  run_snmpwalk $before_file
}
# Option - Run script after upgrade
option_a()
{
  silent_mode
  get_snmp_community
  run_snmpwalk $after_file
  get_before_file
  generate_results
}
# Read the script arguments
get_options()
{
  while getopts ":bahei" option
  do
    case "$option" in
      b) option_b;;
      a) option_a;;
      h) usage;;
      e) error_codes;;
      i) script_information;;
      *) cli_error "Invalid script option" $e_invalid_script_option;;
    esac
  done
}

## Compare Objects ##
# Compare objects

# Get the first SNMP string available in the system
get_snmp_community()
{
  snmp_community=`tmsh list sys snmp communities | fgrep "community-name" | head -n1`
  [[ $? != 0 ]] && error "There is no SNMP community setup" $e_no_snmp_community
  snmp_community=${snmp_community/"            community-name"}
}
# Run snmpwalk command to get the objects
run_snmpwalk()
{
  > $1
  [[ $silent == 0 ]] && menu_file_creating $1

  # LTM module
  ltm_oids=( ltmVsStatusEnabledState ltmVsStatusAvailState ltmPoolStatusEnabledState ltmPoolStatusAvailState \
  ltmPoolMbrStatusEnabledState ltmPoolMbrStatusAvailState ltmNodeAddrStatusEnabledState ltmNodeAddrStatusAvailState )
  for oid in ${ltm_oids[@]}
  do
    # -C I:  don't include the given OID, even if no results are returned
    # -O q:  quick print for easier parsing
    # -r RETRIES set the number of retries
    # -t TIMEOUT set the request timeout (in seconds)
    snmpwalk -CI -Oq -t30 -r0 -c $snmp_community localhost $oid >> $1
    [[ $? != 0 ]] && error "Failure to run snmpwalk" $e_running_snmpwalk
  done

  # bug 364556
  printf "%s \n" ${bug_364556_versions[@]} | grep "$software_version" &> /dev/null
  if [[ $? == 0 ]]
  then
    fgrep ".111.109.109.111.110." $1 &> /dev/null
    if [[ $? == 0 ]]
    then
      [[ $silent == 0 ]] && menu_bug_364556
      sed -i '/.111.109.109.111.110./d' $1
    fi
  fi

  # GTM Module
  if [[ $provision_gtm == 1 ]]
  then
    gtm_oids=( gtmDcStatusEnabledState gtmDcStatusAvailState gtmServerStatusEnabledState gtmServerStatusAvailState \
    gtmWideipStatusEnabledState gtmWideipStatusAvailState gtmPoolStatusEnabledState gtmPoolStatusAvailState  \
    gtmPoolMbrStatusEnabledState gtmPoolMbrStatusAvailState gtmVsStatusEnabledState gtmVsStatusAvailState \
    gtmProberPoolStatusEnabledState gtmProberPoolStatusAvailState gtmProberPoolMbrStatusEnabledState \
    gtmProberPoolMbrStatusAvailState gtmLinkStatusEnabledState gtmLinkStatusAvailState )
    for oid in ${gtm_oids[@]}
    do
      # -C I:  don't include the given OID, even if no results are returned
      # -O q:  quick print for easier parsing
      # -r RETRIES set the number of retries
      # -t TIMEOUT set the request timeout (in seconds)
      snmpwalk -CI -Oq -t30 -r0 -c $snmp_community localhost $oid >> $1
      [[ $? != 0 ]] && error "Failure to run snmpwalk" $e_running_snmpwalk
      #sed -i 's/F5-BIGIP-GLOBAL-MIB:://' $1
    done
  fi
  [[ $silent == 0 ]] && menu_file_created $1
}
# Get before upgrade file
get_before_file()
{
  if [[ $silent == 1 ]]
  then
    before_file=""
    before_file=`ls | fgrep -- "-before-"`
    [[ $before_file == "" ]] && error "Could not find before upgrade file" $e_no_before_upgrade_file
  else
    :
  fi
}
# Load before and after upgrade files to arrays
load_files()
{
  case $1 in
    ltmPoolMbrStatusEnabledState)
      before_object_name=( $(grep $1 $3 | cut -d' ' -f1 | cut -d'.' -f2-) )
      let temp_variable1=${#before_object_name[@]}-1
      for index in `seq 0 $temp_variable1`
      do
        before_object_name[$index]="`echo -n ${before_object_name[$index]} | cut -d'"' -f2`+`echo -n ${before_object_name[$index]} | cut -d'"' -f4`+`echo -n ${before_object_name[$index]} | cut -d'"' -f5 | tr -d '.' | cut -d' ' -f1`"
      done
      after_object_name=( $(grep $1 $4 | cut -d' ' -f1 | cut -d'.' -f2-) )
      let temp_variable1=${#after_object_name[@]}-1
      for index in `seq 0 $temp_variable1`
      do
        after_object_name[$index]="`echo -n ${after_object_name[$index]} | cut -d'"' -f2`+`echo -n ${after_object_name[$index]} | cut -d'"' -f4`+`echo -n ${after_object_name[$index]} | cut -d'"' -f5 | tr -d '.' | cut -d' ' -f1`"
      done
      ;;
      gtmPoolMbrStatusEnabledState)
        before_object_name=( $(grep $1 $3 | cut -d' ' -f1 | cut -d'.' -f2-) )
        let temp_variable1=${#before_object_name[@]}-1
        for index in `seq 0 $temp_variable1`
        do
          before_object_name[$index]="`echo -n ${before_object_name[$index]} | cut -d'"' -f2`+`echo -n ${before_object_name[$index]} | cut -d'"' -f4`+`echo -n ${before_object_name[$index]} | cut -d'"' -f6`"
        done
        after_object_name=( $(grep $1 $4 | cut -d' ' -f1 | cut -d'.' -f2-) )
        let temp_variable1=${#after_object_name[@]}-1
        for index in `seq 0 $temp_variable1`
        do
          after_object_name[$index]="`echo -n ${after_object_name[$index]} | cut -d'"' -f2`+`echo -n ${after_object_name[$index]} | cut -d'"' -f4`+`echo -n ${after_object_name[$index]} | cut -d'"' -f6`"
        done
        ;;
        gtmVsStatusEnabledState|gtmProberPoolMbrStatusEnabledState)
          before_object_name=( $(grep $1 $3 | cut -d' ' -f1 | cut -d'.' -f2-) )
          let temp_variable1=${#before_object_name[@]}-1
          for index in `seq 0 $temp_variable1`
          do
            before_object_name[$index]="`echo -n ${before_object_name[$index]} | cut -d'"' -f2`+`echo -n ${before_object_name[$index]} | cut -d'"' -f4`"
          done
          after_object_name=( $(grep $1 $4 | cut -d' ' -f1 | cut -d'.' -f2-) )
          let temp_variable1=${#after_object_name[@]}-1
          for index in `seq 0 $temp_variable1`
          do
            after_object_name[$index]="`echo -n ${after_object_name[$index]} | cut -d'"' -f2`+`echo -n ${after_object_name[$index]} | cut -d'"' -f4`"
          done
          ;;
    *)
      before_object_name=( $(grep $1 $3 | cut -d'"' -f2) )
      after_object_name=( $(grep $1 $4 | cut -d'"' -f2) )
      ;;
  esac
  before_object_enabled=( $(grep $1 $3 | cut -d' ' -f2) )
  before_object_status=( $(grep $2 $3 | cut -d' ' -f2) )
  after_object_enabled=( $(grep $1 $4 | cut -d' ' -f2) )
  after_object_status=( $(grep $2 $4 | cut -d' ' -f2) )
}
# Generate object table
generate_object_table()
{
  [[ $# == 3 ]] && html_table_object_header "$1" "$2" "$3" >> $html_tables_file
  [[ $# == 4 ]] && html_table_object_header "$1" "$2" "$3" "$4" >> $html_tables_file
  [[ $# == 5 ]] && html_table_object_header "$1" "$2" "$3" "$4" "$5" >> $html_tables_file
  let temp_variable1=${#before_object_name[@]}-1
  let temp_variable2=${#after_object_name[@]}-1
  for index in `seq 0 $temp_variable1`
  do
    # If the same device, most likely the order of the objects will be same for both files
    # To avoid a second loop, test if is the same first
    if [[ ${before_object_name[$index]} == ${after_object_name[$index]} ]]
    then
      if [[ ${before_object_enabled[$index]} != ${after_object_enabled[$index]} ]] || [[ ${before_object_status[$index]} != ${after_object_status[$index]} ]]
      then
        let changes=changes+1
        html_table_object_row "red" ${before_object_name[$index]} ${before_object_enabled[$index]} ${after_object_enabled[$index]} \
        ${before_object_status[$index]} ${after_object_status[$index]} "Changed" >> $html_tables_file
      else
        html_table_object_row "white" ${before_object_name[$index]} ${before_object_enabled[$index]} ${after_object_enabled[$index]} \
        ${before_object_status[$index]} ${after_object_status[$index]} "Same" >> $html_tables_file
      fi
    else
      for index2 in `seq 0 $temp_variable2`
      do
        if [[ ${before_object_name[$index]} == ${after_object_name[$index2]} ]]
        then
          if [[ ${before_object_enabled[$index]} != ${after_object_enabled[$index2]} ]] || [[ ${before_object_status[$index]} != ${after_object_status[$index2]} ]]
          then
            let changes=changes+1
            html_table_object_row "red" ${before_object_name[$index]} ${before_object_enabled[$index]} ${after_object_enabled[$index2]} \
            ${before_object_status[$index]} ${after_object_status[$index]} "Changed" >> $html_tables_file
          else
            html_table_object_row "white" ${before_object_name[$index]} ${before_object_enabled[$index]} ${after_object_enabled[$index2]} \
            ${before_object_status[$index]} ${after_object_status[$index2]} "Same" >> $html_tables_file
          fi
        fi
      done
    fi
  done
  html_table_object_tail >> $html_tables_file
}
# Generate total table row
generate_total_table_row()
{
  if [[ ${#before_object_name[@]} == ${#after_object_name[@]} ]]
  then
    html_table_total_row "white" "$1" ${#before_object_name[@]} ${#after_object_name[@]} >> $html_file
  else
    let changes=changes+1
    http_table_total_row "red" "$1" ${#before_object_name[@]} ${#after_object_name[@]} >> $html_file
  fi
}
# Merge files, total table first and object tables after
merge_files()
{
  cat $html_tables_file >> $html_file
  rm -f $html_tables_file
}
# Generate the results to the HTML files
generate_results()
{
  changes=0
  html_head > $html_file
  > $html_tables_file

  # LTM Module
  html_table_total_header "LTM" >> $html_file

  # LTM Module Virtual
  [[ $silent == 0 ]] && infobox "Calculating" "Virtual Server..." 0 0
  load_files "ltmVsStatusEnabledState" "ltmVsStatusAvailState" $before_file $after_file
  generate_object_table "LTM - Virtual Server" "ltm_virtual_server" "Virtual Server"
  generate_total_table_row "Virtual Server"

  # LTM Module Pool
  [[ $silent == 0 ]] && infobox "Calculating" "LTM Pool..." 0 0
  load_files "ltmPoolStatusEnabledState" "ltmPoolStatusAvailState" $before_file $after_file
  generate_object_table "LTM - Pool" "ltm_pool" "Pool"
  generate_total_table_row "Pool"

  # LTM Module Pool Member
  [[ $silent == 0 ]] && infobox "Calculating" "LTM Pool Member..." 0 0
  load_files "ltmPoolMbrStatusEnabledState" "ltmPoolMbrStatusAvailState" $before_file $after_file
  generate_object_table "LTM - Pool Member" "ltm_pool_member" "Pool" "Node" "Port"
  generate_total_table_row "Pool Member"

  # LTM Module Node
  [[ $silent == 0 ]] && infobox "Calculating" "LTM Node..." 0 0
  load_files "ltmNodeAddrStatusEnabledState" "ltmNodeAddrStatusAvailState" $before_file $after_file
  generate_object_table "LTM - Node" "ltm_node" "Node"
  generate_total_table_row "Node"

  html_table_total_tail "LTM" >> $html_file

  # GTM Module
  if [[ $provision_gtm == 1 ]]
  then
    html_table_total_header "GTM" >> $html_file

    # GTM Module Data Center
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Data Center..." 0 0
    load_files "gtmDcStatusEnabledState" "gtmDcStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Data Center" "gtm_data_center" "Data Center"
    generate_total_table_row "Data Center"

    # GTM Module Server
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Server..." 0 0
    load_files "gtmServerStatusEnabledState" "gtmServerStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Server" "gtm_server" "Server"
    generate_total_table_row "Server"

    # GTM Module Wide IP
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Wide IP..." 0 0
    load_files "gtmWideipStatusEnabledState" "gtmWideipStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Wide IP" "gtm_wideip" "Wide IP"
    generate_total_table_row "Wide IP"

    # GTM Module Pool
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Pool..." 0 0
    load_files "gtmPoolStatusEnabledState" "gtmPoolStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Pool" "gtm_pool" "Pool"
    generate_total_table_row "Pool"

    # GTM Module Pool Member
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Pool Member..." 0 0
    load_files "gtmPoolMbrStatusEnabledState" "gtmPoolMbrStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Pool Member" "gtm_pool_member" "Pool" "Server" "Virtual Server"
    generate_total_table_row "Pool Member"

    # GTM Module Virtual Server
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Virtual Server..." 0 0
    load_files "gtmVsStatusEnabledState" "gtmVsStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Virtual Server" "gtm_virtual_server" "Server" "Virtual Server"
    generate_total_table_row "Virtual Server"

    # GTM Module Prober Pool
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Prober Pool..." 0 0
    load_files "gtmProberPoolStatusEnabledState" "gtmProberPoolStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Prober Pool" "gtm_prober_pool" "Prober Pool"
    generate_total_table_row "Prober Pool"

    # GTM Module Prober Pool Member
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Prober Pool Member..." 0 0
    load_files "gtmProberPoolMbrStatusEnabledState" "gtmProberPoolMbrStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Prober Pool Member" "gtm_prober_pool_member" "Prober Pool" "Server"
    generate_total_table_row "Prober Pool Member"

    # GTM Module Link
    [[ $silent == 0 ]] && infobox "Calculating" "GTM Link..." 0 0
    load_files "gtmLinkStatusEnabledState" "gtmLinkStatusAvailState" $before_file $after_file
    generate_object_table "GTM - Link" "gtm_link" "Link"
    generate_total_table_row "Link"

    html_table_total_tail "GTM" >> $html_file
  fi

  merge_files
  html_tail >> $html_file
  if [[ $changes == 0 ]]
  then
    sed -i 's/0123456789/No changes/' $html_file
  else
    sed -i 's/0123456789/Changes found/' $html_file
  fi
  sed -i s\/1234567890\/$changes\/ $html_file
  [[ $silent == 0 ]] && menu_file_created $html_file
}

## HTML ##
# Create HTML code

# Code for first part of the HTMl file
html_head()
{
  echo "<html>"
  echo "<head>"
  echo "<title>$script_name</title>"
  echo "</head>"
  echo "<body>"
  echo "<center>"
  echo "<p><font size="10">$script_name</font></p>"
  echo "<p><font size="5">`date "+%Y/%m/%d %H:%M"`</font></p>"
  echo "<br>"
  echo "<p><font size="5">Upgrade Status</font></p>"
  echo "<p><font size="4">0123456789</font></p>"
  echo "<p><font size="5">Number of Changes</font></p>"
  echo "<p><font size="4">1234567890</font></p>"
  echo "<br>"
}
# Code for last part of the HTMl file
# Includes TableFilter v0.6.21 to provide filtering functionality using Javascript to the tables
# http://koalyptus.github.io/TableFilter/
html_tail()
{
  echo "</center>"
  echo '<script src="tablefilter.js"></script>'
  cat <<HereDocument
<script data-config>
  var filtersConfig = {
      col_1: 'select',
      col_2: 'select',
      col_3: 'select',
      col_4: 'select'
  };
  var ltm_virtual_server = new TableFilter('ltm_virtual_server', filtersConfig);
  ltm_virtual_server.init();
  var ltm_pool = new TableFilter('ltm_pool', filtersConfig);
  ltm_pool.init();
  var ltm_pool_member = new TableFilter('ltm_pool_member', filtersConfig);
  ltm_pool_member.init();
  var ltm_node = new TableFilter('ltm_node', filtersConfig);
  ltm_node.init();
  var gtm_wideip = new TableFilter('gtm_wideip', filtersConfig);
  gtm_wideip.init();
  var gtm_pool = new TableFilter('gtm_pool', filtersConfig);
  gtm_pool.init();
  var gtm_pool_member = new TableFilter('gtm_pool_member', filtersConfig);
  gtm_pool_member.init();
  var gtm_server = new TableFilter('gtm_server', filtersConfig);
  gtm_server.init();
  var gtm_virtual_server = new TableFilter('gtm_virtual_server', filtersConfig);
  gtm_virtual_server.init();
  var gtm_data_center = new TableFilter('gtm_data_center', filtersConfig);
  gtm_data_center.init();
  var gtm_link = new TableFilter('gtm_link', filtersConfig);
  gtm_link.init();
  var gtm_prober_pool = new TableFilter('gtm_prober_pool', filtersConfig);
  gtm_prober_pool.init();
  var gtm_prober_pool_member = new TableFilter('gtm_prober_pool_member', filtersConfig);
  gtm_prober_pool_member.init();
</script>
HereDocument
  echo "</body>"
  echo "</html>"
}
# Code for first part of the total table
html_table_total_header()
{
  echo "<p><font size="5">${1} Total</font></p>"
  echo "<table id="total" border="1">"
  echo "<tr>"
  echo "<th>Object</th>"
  echo "<th>Before Upgrade</th>"
  echo "<th>After Upgrade</th>"
  echo "</tr>"
}
# Code for last part of the HTMl file
html_table_total_tail()
{
  echo "</table>"
}
# Code for a row of the total table
html_table_total_row()
{
  echo "<tr>"
  echo "<td bgcolor="$1">$2</td>"
  echo "<td bgcolor="$1">$3</td>"
  echo "<td bgcolor="$1">$4</td>"
  echo "</tr>"
}
# Code for first part of the object table
html_table_object_header()
{
  echo "<p><font size="5">$1</font></p>"
  echo "<table id="$2" border="1">"
  echo "<tr>"
  echo "<th>$3</th>"
  [[ $# > 3 ]] && echo "<th>$4</th>"
  [[ $# > 4 ]] && echo "<th>$5</th>"
  echo "<th>Before Upgrade - Enabled</th>"
  echo "<th>After Upgrade - Enabled</th>"
  echo "<th>Before Upgrade - Status</th>"
  echo "<th>After Upgrade - Status</th>"
  echo "<th>Result</th>"
  echo "</tr>"
}
# Code for a row of the object table
html_table_object_row()
{
  echo "<tr>"
  temp_variable1=`grep -o '+' <<< $2 | wc -l`
  case $temp_variable1 in
    0) echo "<td bgcolor="$1">$2</td>";;
    1)
      echo "<td bgcolor="$1">`cut -d'+' -f1 <<< $2`</td>"
      echo "<td bgcolor="$1">`cut -d'+' -f2 <<< $2`</td>";;
    2)
        echo "<td bgcolor="$1">`cut -d'+' -f1 <<< $2`</td>"
        echo "<td bgcolor="$1">`cut -d'+' -f2 <<< $2`</td>"
        echo "<td bgcolor="$1">`cut -d'+' -f3 <<< $2`</td>";;
  esac
  echo "<td bgcolor="$1">$3</td>"
  echo "<td bgcolor="$1">$4</td>"
  echo "<td bgcolor="$1">$5</td>"
  echo "<td bgcolor="$1">$6</td>"
  echo "<td bgcolor="$1">$7</td>"
  echo "</tr>"
}
# Code for last part of the object table
html_table_object_tail()
{
  echo "</table>"
}

## Menu ##
# Create dialog menus

# Display a dialog box with a message, with a ok button
msgbox()
{
  dialog --backtitle "$script_name - $HOSTNAME - $product $software_version" --title "$1" --msgbox "$2" $3 $4
}
# Display a dialog box with information, without buttons
infobox()
{
  dialog --backtitle "$script_name - $HOSTNAME - $product $software_version" --title "$1" --infobox "$2" $3 $4
}
# Display a dialog menu with multiple options
menu_main()
{
  while true
  do
    exec 3>&1
    option=`dialog --cancel-label "Exit" --backtitle "$script_name - $HOSTNAME - $product $software_version" --title "Menu" --menu \
      "Select one option:" 10 50 3 \
      "1" "Run script before upgrade" \
      "2" "Run script after upgrade" \
      "3" "Script Information" 2>&1 1>&3`
    exit_status=$?
    exec 3>&-
     if [[ $exit_status == $dialog_esc ]] || [[ $exit_status == $dialog_cancel ]]
     then
       exit 0
     fi
     case $option in
       1) option_1;;
       2) option_2;;
       3) option_3;;
     esac
   done
}
# Option 1 - Run script before upgrade
option_1()
{
  get_snmp_community
  run_snmpwalk $before_file
}
# Option 2 - Run script after upgrade
option_2()
{
  get_snmp_community
  run_snmpwalk $after_file
  get_before_file
  generate_results
}
# Option 3 - Script Information
option_3()
{
  message=`printf "Author: $script_author\nVersion: $script_version\nDate: $script_date"`
  msgbox "Script Information" "$message" 7 28
}
# Display a message about bug ID 364556
menu_bug_364556()
{
  message=`printf "This device is affected by the following bug:\nhttps://support.f5.com/csp/article/K14618\nSome pool members will be omited from results."`
  msgbox "Bug Information" "$message" 7 50
}
# Display a message indicating that a file is been created
menu_file_creating(){
  message=`printf "File:\n$1\nIs been created..."`
  infobox "File" "$message" 0 0
}
# Display a message indicating that a file has been created
menu_file_created(){
  message=`printf "File:\n$1\nWas created sucessfully."`
  msgbox "File" "$message" 0 0
}

## Main ##
# Run the script functions

script_information_variables
check_product
check_version
check_provision
if [[ $# -ne "0" ]]
then
{
  get_options $@
}
fi
if [[ $# -eq "0" ]]
then
{
  menu_main
}
fi
exit 0