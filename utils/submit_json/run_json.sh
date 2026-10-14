#!/bin/bash




function getJsonVal () {
  val=$(${_python} -c "import json;print(json.dumps(json.load(open('${config}'))$1))";)
  eval echo ${val}
} # e.x. 'outPath=$(getJsonVal "['transport']['output']['path']")'

#function checkJsonKey () {
#  python -c "import json,sys;print ('$1' in json.load(open('${config}')))";
#} # returns True if key exists, False if not, e.x. 'run_transport=$(checkJsonKey "transport")'

function readStepInfo () {
  run=$(getJsonVal "['accessory']['${step}']['run']")
  if [ ${run} == true ]; then
    overwrite=$(getJsonVal "['${step}']['output']['overwrite']")
    outDir=$(getJsonVal "['${step}']['output']['path']")
    [[ ${outDir} != */ ]] && outDir=$(dirname ${outFile})
    srcDir=${outDir}/macro
    macro=$(getJsonVal "['accessory']['${step}']['macro']")
    macroName=$(basename ${macro})
  fi
}

# find the proper python executable and exit if not found
if [[ ! -z $PYHON_EXEC ]]; then
  _python=$PYHON_EXEC
elif command -v python > /dev/null 2>&1; then
  _python=python
elif command -v python3 > /dev/null 2>&1; then
  _python=python3
elif command -v python2 > /dev/null 2>&1; then
  _python=python2
else
  echo "No python interpreter found with the standard commands (PYTHON_EXEC env, python, python3,python2)"
  exit 1
fi
export _python=${_python}
echo "Python :        ${_python}"

submitScript=${0}
echo "Submit script : ${submitScript}"
config=${1}
echo "Config file :   ${config}"
batch=$(getJsonVal "['accessory']['batch']")
export cbmRoot=$(getJsonVal "['accessory']['cbmRoot']")
cbmRoot="${cbmRoot} -a"
echo "CbmRoot : ${cbmRoot}"
source ${cbmRoot}
jobScript=$(getJsonVal "['accessory']['jobScript']")


steps="transport digitization reconstruction AT"
for step in ${steps}; do
  readStepInfo
  if [ ${run} == true ]; then
    mkdir -pv ${srcDir}
    rsync -uv ${macro} ${srcDir}
    rsync -uv ${config} ${srcDir}
    rsync -uv ${submitScript} ${srcDir}
    rsync -uv ${jobScript} ${srcDir}
  fi
done

export -f getJsonVal
export -f readStepInfo

export configName=$(basename ${config})
export config=${srcDir}/${configName}
export nEvents=$(getJsonVal "['accessory']['nEvents']")
jobRange=$(getJsonVal "['accessory']['jobRange']")
logDir=$(getJsonVal "['accessory']['logDir']")
mkdir -pv ${logDir}

if [ ${batch} == true ];then
  account=$(getJsonVal "['accessory']['account']")
  ram=$(getJsonVal "['accessory']['ram']")
  partition=$(getJsonVal "['accessory']['partition']")
  time=$(getJsonVal "['accessory']['time']")
  jobName=$(getJsonVal "['accessory']['jobName']")
  excludeNodes=$(getJsonVal "['accessory']['excludeNodes']")
  sbatch -A ${account} --mem=${ram} -p ${partition} -t ${time} -J ${jobName}\
    -a ${jobRange} -o ${logDir}/%a_%A.log --export=ALL \
    --exclude=${excludeNodes} -- ${jobScript}
else
  echo "Jobscript: ${jobScript}"
  if [[ ${jobRange} =~ "-" ]]
  then
    # specified range > 1 for non-batch mode
    start=$(echo ${jobRange} | cut -d '-' -f 1)
    stop=$(echo ${jobRange} | cut -d '-' -f 2)
    for (( ijob=${start}; ijob<=${stop}; ijob++ ))
    do
      nohup bash -c 'export SLURM_ARRAY_TASK_ID="$0" && "$1"' "${ijob}" "${jobScript}" > ${logDir}/${ijob}.log 2>&1 &
    done
  else
    # single non-batch execution
    export SLURM_ARRAY_TASK_ID=${jobRange}
    ${jobScript} &> ${logDir}/${jobRange}.log
  fi
fi
