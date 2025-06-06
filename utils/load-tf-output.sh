#/bin/bash -x

source ./params.sh
source ./utils/utils.sh

TMP_FILE=/tmp/load-tf-output.tmp.$$

Log "Collecting terraform output values.."

# Collect node details from terraform output
CWD=`pwd`
cd tf
terraform output > $TMP_FILE
cd $CWD

# Some parsing into shell variables and arrays
DATA=`cat $TMP_FILE |sed "s/'//g"|sed 's/\ =\ /=/g'`
DATA2=`echo $DATA |sed 's/\ *\[/\[/g'|sed 's/\[\ */\[/g'|sed 's/\ *\]/\]/g'|sed 's/\,\ */\,/g'`

for var in `echo $DATA2`
do
  var_name=`echo $var | awk -F"=" '{print $1}'`
  var_value=`echo $var | awk -F"=" '{print $2}'|sed 's/\]//g'|sed 's/\[//g' |sed 's/\"//g'`
  #echo TF_OUTPUT: $var_name: $var_value

  case $var_name in

    "domainname")
      for entry in $(echo $var_value |sed "s/,/ /g")
      do
        DOMAINNAME=$entry
      done
      ;;

    "instance-names")
      COUNT=0
      for entry in $(echo $var_value |sed "s/,/ /g")
      do
        COUNT=$(($COUNT+1))
        NODE_NAME[$COUNT]=$entry
      done
      NUM_NODES=$COUNT
      ;;

    "instance-private-ips")
      COUNT=0
      for entry in $(echo $var_value |sed "s/,/ /g")
      do
        COUNT=$(($COUNT+1))
        NODE_PRIVATE_IP[$COUNT]=$entry
      done
      ;;

    "instance-public-ips")
      COUNT=0
      for entry in $(echo $var_value |sed "s/,/ /g")
      do
        COUNT=$(($COUNT+1))
        NODE_PUBLIC_IP[$COUNT]=$entry
      done
      ;;

  esac
done

# map to simple arrays
for ((i=1; i<=$NUM_NODES; i++))
do
  echo ${NODE_NAME[$i]} ${NODE_PUBLIC_IP[$i]} ${NODE_PRIVATE_IP[$i]}
done
echo 

# Tidy up
/bin/rm $TMP_FILE

