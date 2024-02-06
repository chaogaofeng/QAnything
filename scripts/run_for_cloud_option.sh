#!/bin/bash

update_or_append_to_env() {
  local key=$1
  local value=$2
  local env_file="/workspace/qanything_local/.env"

  # 检查键是否存在于.env文件中
  if grep -q "^${key}=" "$env_file"; then
    # 如果键存在，则更新它的值
    sed -i "/^${key}=/c\\${key}=${value}" "$env_file"
  else
    # 如果键不存在，则追加键值对到文件
    echo "${key}=${value}" >> "$env_file"
  fi
}

function check_log_errors() {
    local log_file=$1  # 将第一个参数赋值给变量log_file，表示日志文件的路径

    # 检查日志文件是否存在
    if [[ ! -f "$log_file" ]]; then
        echo "指定的日志文件不存在: $log_file"
        return 1
    fi

    # 使用grep命令检查"core dumped"或"Error"的存在
    # -C 5表示打印匹配行的前后各5行
    local pattern="core dumped|Error|error"
    if grep -E -C 5 "$pattern" "$log_file"; then
        echo "检测到错误信息，请查看上面的输出。"
        exit 1
    else
        echo "$log_file 中未检测到明确的错误信息。请手动排查 $log_file 以获取更多信息。"
    fi
}

script_name=$(basename "$0")

usage() {
  echo "Usage: $script_name [-c <llm_api>] [-i <device_id>] [-b <runtime_backend>] [-m <model_name>] [-t <conv_template>] [-p <tensor_parallel>] [-r <gpu_memory_utilization>] [-h]"
  echo "  -c : Options {local, cloud} to specify the llm API mode, default is 'local'. If set to '-c cloud', please mannually set the environments {OPENAI_API_KEY, OPENAI_API_BASE, OPENAI_API_MODEL_NAME, OPENAI_API_CONTEXT_LENGTH} into .env fisrt in run.sh"
  echo "  -i <device_id>: Specify argument GPU device_id"
  echo "  -b <runtime_backend>: Specify argument LLM inference runtime backend, options={default, hf, vllm}"
  echo "  -m <model_name>: Specify argument the path to load LLM model using FastChat serve API, options={Qwen-7B-Chat, deepseek-llm-7b-chat, ...}"
  echo "  -t <conv_template>: Specify argument the conversation template according to the LLM model when using FastChat serve API, options={qwen-7b-chat, deepseek-chat, ...}"
  echo "  -p <tensor_parallel>: Use options {1, 2} to set tensor parallel parameters for vllm backend when using FastChat serve API, default tensor_parallel=1"
  echo "  -r <gpu_memory_utilization>: Specify argument gpu_memory_utilization (0,1] for vllm backend when using FastChat serve API, default gpu_memory_utilization=0.81"
  echo "  -h: Display help usage message"
  exit 1
}

llm_api="local"
device_id="0"
runtime_backend="default"
model_name=""
conv_template=""
tensor_parallel=1
gpu_memory_utilization=0.81

# 解析命令行参数
while getopts ":c:i:b:m:t:p:r:h" opt; do
  case $opt in
    c) llm_api=$OPTARG ;;
    i) device_id=$OPTARG ;;
    b) runtime_backend=$OPTARG ;;
    m) model_name=$OPTARG ;;
    t) conv_template=$OPTARG ;;
    p) tensor_parallel=$OPTARG ;;
    r) gpu_memory_utilization=$OPTARG ;;
    h) usage ;;
    *) usage ;;
  esac
done

echo "llm_api is set to [$llm_api]"
echo "device_id is set to [$device_id]"
echo "runtime_backend is set to [$runtime_backend]"
echo "model_name is set to [$model_name]"
echo "conv_template is set to [$conv_template]"
echo "tensor_parallel is set to [$tensor_parallel]"
echo "gpu_memory_utilization is set to [$gpu_memory_utilization]"

check_folder_existence() {
  if [ ! -d "/model_repos/CustomLLM/$1" ]; then
    echo "The $1 folder does not exist under QAnything/assets/custom_models/. Please check your setup."
    echo "在QAnything/assets/custom_models/下不存在$1文件夹。请检查您的模型文件。"
    exit 1
  fi
}

start_time=$(date +%s)  # 记录开始时间 

mkdir -p /model_repos/QAEnsemble_embed_rerank && mkdir -p /workspace/qanything_local/logs/debug_logs && mkdir -p /workspace/qanything_local/logs/qa_logs

if [ ! -L "/model_repos/QAEnsemble_embed_rerank/rerank" ]; then
  cd /model_repos/QAEnsemble_embed_rerank && ln -s /model_repos/QAEnsemble/rerank .
fi

if [ ! -L "/model_repos/QAEnsemble_embed_rerank/embed" ]; then
  cd /model_repos/QAEnsemble_embed_rerank && ln -s /model_repos/QAEnsemble/embed .
fi

# 设置默认值
default_gpu_id1=0
default_gpu_id2=0

# 检查环境变量GPUID1是否存在，并读取其值或使用默认值
if [ -z "${GPUID1}" ]; then
    gpuid1=$default_gpu_id1
else
    gpuid1=${GPUID1}
fi

# 检查环境变量GPUID2是否存在，并读取其值或使用默认值
if [ -z "${GPUID2}" ]; then
    gpuid2=$default_gpu_id2
else
    gpuid2=${GPUID2}
fi
echo "GPU ID: $gpuid1, $gpuid2"

echo "The triton server will start on $gpuid1 GPU"

CUDA_VISIBLE_DEVICES=$gpuid1 nohup /opt/tritonserver/bin/tritonserver --model-store=/model_repos/QAEnsemble_embed_rerank --http-port=9000 --grpc-port=9001 --metrics-port=9002 --log-verbose=1 > /workspace/qanything_local/logs/debug_logs/embed_rerank_tritonserver.log 2>&1 &

update_or_append_to_env "EMBED_PORT" "9001"
update_or_append_to_env "RERANK_PORT" "9001"

cd /workspace/qanything_local || exit
nohup python3 -u qanything_kernel/dependent_server/rerank_for_local_serve/rerank_server.py > /workspace/qanything_local/logs/debug_logs/rerank_server.log 2>&1 &
echo "The rerank service is ready! (2/8)"
echo "rerank服务已就绪! (2/8)"

CUDA_VISIBLE_DEVICES=$gpuid2 nohup python3 -u qanything_kernel/dependent_server/ocr_serve/ocr_server.py > /workspace/qanything_local/logs/debug_logs/ocr_server.log 2>&1 &
echo "The ocr service is ready! (3/8)"
echo "OCR服务已就绪! (3/8)"

nohup python3 -u qanything_kernel/qanything_server/sanic_api.py --mode "online" > /workspace/qanything_local/logs/debug_logs/sanic_api.log 2>&1 &
echo "The qanything backend service is ready! (4/8)"
echo "qanything后端服务已就绪! (4/8)"


env_file="/workspace/qanything_local/front_end/.env.production"
user_file="/workspace/qanything_local/user.config"
user_ip=$(cat "$user_file")
# 读取env_file的第一行
current_host=$(grep VITE_APP_API_HOST "$env_file")
user_host="VITE_APP_API_HOST=http://$user_ip:8777"
# 检查current_host与user_host是否相同
if [ "$current_host" != "$user_host" ]; then
   # 使用 sed 命令更新 VITE_APP_API_HOST 的值
   sed -i "s|VITE_APP_API_HOST=.*|$user_host|" "$env_file"
   echo "The file $env_file has been updated with the following configuration:"
   grep "VITE_APP_API_HOST" "$env_file"
fi

# 转到 front_end 目录
cd /workspace/qanything_local/front_end || exit
# 安装依赖
echo "Waiting for [npm run install]（5/8)"
npm config set registry https://registry.npmmirror.com
timeout 180 npm install
if [ $? -eq 0 ]; then
    echo "[npm run install] Installed successfully（5/8)"
elif [ $? -eq 124 ]; then
    echo "npm install 下载超时(180秒)，可能是网络问题，请修改 npm 代理。"
    exit 1
else
    echo "Failed to install npm dependencies."
    exit 1
fi

# 构建前端项目
echo "Waiting for [npm run build](6/8)"
timeout 180 npm run build
if [ $? -eq 0 ]; then
    echo "[npm run build] build successfully(6/8)"
elif [ $? -eq 124 ]; then
    echo "npm run build 编译超时(180秒)，请查看上面的输出。"
    exit 1
else
    echo "Failed to build the front end."
    exit 1
fi

# 启动前端页面服务
nohup npm run serve 1>/workspace/qanything_local/logs/debug_logs/npm_server.log 2>&1 &

# 监听前端页面服务
tail -f /workspace/qanything_local/logs/debug_logs/npm_server.log &

front_end_start_time=$(date +%s)

while ! grep -q "Local:" /workspace/qanything_local/logs/debug_logs/npm_server.log; do
    echo "Waiting for the front-end service to start..."
    echo "等待启动前端服务"
    sleep 1

    # 获取当前时间并计算经过的时间
    current_time=$(date +%s)
    elapsed_time=$((current_time - front_end_start_time))

    # 检查是否超时
    if [ $elapsed_time -ge 120 ]; then
        echo "启动前端服务超时，请检查日志文件 /workspace/qanything_local/logs/debug_logs/npm_server.log 获取更多信息。"
        exit 1
    fi
done
echo "The front-end service is ready!...(7/8)"
echo "前端服务已就绪!...(7/8)"

embed_rerank_log_file="/workspace/qanything_local/logs/debug_logs/embed_rerank_tritonserver.log"

tail -f $embed_rerank_log_file &  # 后台输出日志文件
tail_pid=$!  # 获取tail命令的进程ID

now_time=$(date +%s)
while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - now_time))

    if [ "$runtime_backend" = "default" ]; then
        response_embed_rerank=$(curl -s -w "%{http_code}" http://localhost:9000/v2/health/ready -o /dev/null)
        echo "health response_embed_rerank = $response_embed_rerank"

        # 检查是否超时
        if [ $elapsed_time -ge 60 ]; then
            kill $tail_pid  # 关闭后台的tail命令
            echo "启动 embedding and rerank 服务超时，自动检查 $embed_rerank_log_file 中是否存在Error..."

            check_log_errors $embed_rerank_log_file

            exit 1
        fi

        if [ "$response_embed_rerank" -eq 200 ]; then
            kill $tail_pid  # 关闭后台的tail命令
            echo "The embedding and rerank service is ready!, now you can use the qanything service. (8/8)"
            echo "Embedding 和 Rerank 服务已准备就绪！现在您可以使用qanything服务。（8/8)"
            break
        fi

        echo "The embedding and rerank service is starting up, it can be long... you have time to make a coffee :)"
        echo "Embedding and Rerank 服务正在启动，可能需要一段时间...你有时间去冲杯咖啡 :)"
        sleep 10

    else
        # cloud版本runtime只支持default
        echo "runtime_backend only support default in cloud version."
        exit 1
    fi
done

echo "开始检查日志文件中的错误信息..."
# 调用函数并传入日志文件路径
check_log_errors "/workspace/qanything_local/logs/debug_logs/rerank_server.log"
check_log_errors "/workspace/qanything_local/logs/debug_logs/ocr_server.log"
check_log_errors "/workspace/qanything_local/logs/debug_logs/sanic_api.log"

current_time=$(date +%s)
elapsed=$((current_time - start_time))  # 计算经过的时间（秒）
echo "Time elapsed: ${elapsed} seconds."
echo "已耗时: ${elapsed} 秒."
echo "Please visit the front-end service at [http://$user_ip:5052/qanything/] to conduct Q&A."
echo "请在[http://$user_ip:5052/qanything/]下访问前端服务来进行问答，如果前端报错，请在浏览器按F12以获取更多报错信息"

# 保持容器运行
while true; do
  sleep 2
done


