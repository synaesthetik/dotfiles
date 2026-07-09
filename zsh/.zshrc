### PATH ###
export PATH=$HOME/bin:/usr/local/bin:/Users/patrick.lewis/code/infrastructure/bin:/usr/local/go/bin:$PATH
export PATH=$HOME/.asdf/shims:$PATH
export PATH="/opt/homebrew/bin:$PATH"
export PATH="/opt/homebrew/sbin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
export LIBPQ_INCLUDE_DIR=$(brew --prefix libpq)/include
export LIBPQ_LIB_DIR=$(brew --prefix libpq)/lib
export INFRA_HOME=/Users/patrick.lewis/code/infrastructure

### THEME ###
export ZSH_THEME="powerlevel10k/powerlevel10k"

export EDITOR="code --wait"

#COMPLETION_WAITING_DOTS="true"

### OVERRIDES ###
export FZF_ALT_C_COMMAND=''

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh


plugins=(git macos zsh-syntax-highlighting)
source ~/.oh-my-zsh/oh-my-zsh.sh

### AWS ###
export AWS_VAULT_BACKEND=file
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
export AWS_SDK_LOAD_CONFIG=true
export AWS_DEFAULT_PROFILE="dev.use1"
export AWS_PROFILE="dev.use1"
export AWS_SESSION_TOKEN_TTL=12h

### GO ###
export GO111MODULE=auto
export GODEBUG=asyncpreemptoff=1
export GOPATH=~/.go
export GOBIN=~/.go/bin/

## GHR LOCAL ##
export PGHOST=localhost
export PGUSER=postgres
export PGDATA=/var/lib/postgresql/data/pgdata

### PYTHON ###
export PYENV_ROOT=/Users/patrick.lewis/.pyenv
export PYENV_ROOT="$HOME/.pyenv"
export VIRTUAL_ENV_DISABLE_PROMPT=1
if which pyenv > /dev/null; then eval "$(pyenv init - zsh)"; fi
if which pyenv-virtualenv-init > /dev/null; then eval "$(pyenv virtualenv-init - zsh)"; fi

### SEND_SAFELY ###

### TERRAFORM ###
export TF_PLUGIN_CACHE_DIR=/Users/patrick.lewis/.terraform-cache
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true

### TESTING ###

### Functions ####

awsc () {
  local _profile
  _profile="$AWS_PROFILE"
  _path="${1}"
  [[ -n $_path ]] && shift
  aws-vault login "${_profile}" --path="${_path}" "$@"
}

ap () {
  export AWS_PROFILE=$(aws configure list-profiles | fzf)
}

n2ip () {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=*${1}*" Name=instance-state-name,Values=running | jq -r '.Reservations[].Instances[] | [.NetworkInterfaces[0].PrivateIpAddress, (.Tags[] | select(.Key == "Name").Value),(.InstanceId),(.LaunchTime)] | join("\t")'
}

asgterm () {
  aws autoscaling terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity --instance-id $1
}

cdir () {
local target
  target=$(dirs -v | fzf | awk '{ print $1}')
  if [[ -n $target ]]; then cd ~$target; fi
}

get-codeart-token () {
  aws codeartifact get-authorization-token --domain grnhse --query authorizationToken --output text
}

asgterm_dns() {
  local _instance_dns_name _instance_id
  _instance_dns_name="${1}"
  _instance_id="$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running Name=private-dns-name,Values="${_instance_dns_name}" | jq '.Reservations[].Instances[].InstanceId' -r | head -1)"
  if [ -z "${_instance_id}" ]; then
    >&2 echo "Didn't find any instance ID with private dns name: ${_instance_dns_name}"
    return 1
  else
    >&2 echo "About to delete instance id: ${_instance_id}..."
    sleep 3
    echo aws autoscaling terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity --instance-id "${_instance_id}"
  fi
}

provider-clean () {
  for k in $(env | grep TF_VAR | cut -f 1 -d =); do unset ${k}; done
}

clm () {
  awk "{ print \$${1} }"
}

get-asgs () {
  aws autoscaling describe-auto-scaling-groups | jq -er '.AutoScalingGroups[].AutoScalingGroupName'
}

asgtags () {
  aws autoscaling describe-tags --filters Name=auto-scaling-group,Values=$1
}

param () {
  aws ssm get-parameters --with-decryption --names "$(aws ssm get-parameters-by-path --path / --recursive \
  | jq -r '.Parameters[].Name' | fzf)" | jq -er '.Parameters[].Value' | pbcopy
}

colormap () {
  for i in {0..255}; do print -Pn "%K{$i}  %k%F{$i}${(l:3::0:)i}%f " ${${(M)$((i%6)):#3}:+$'\n'}; done
}

branch-clean () {
  git branch -r | awk '{print $1}' | egrep -v -f /dev/fd/0 <(git branch -vv | grep origin) | awk '{print $1}' | xargs git branch -d
}

codeartifact-poetry () {
  export CODEARTIFACT_TOKEN=$(
    aws codeartifact get-authorization-token \
    --domain grnhse --domain-owner 874364631781 \
    --query authorizationToken --output text \
    )
  export POETRY_HTTP_BASIC_CODEARTIFACT_USERNAME="aws"
  export POETRY_HTTP_BASIC_CODEARTIFACT_PASSWORD="${CODEARTIFACT_TOKEN}"
}

ssmlist() {
  aws ssm describe-parameters | jq '.Parameters[].Name' -r | grep "${1:-.*}"
}

ssmget() {
  aws ssm get-parameter --name $1 --with-decryption | jq '.Parameter.Value' -r
}

exhibit() {
  clusters=($(ssmlist zookeeper | grep -v "/us-"))
  for cluster in $clusters; do
    echo "Cluster: $cluster"
    key=$(echo $cluster | sed 's@/@ @g' | awk '{print $2"-zookeeper"}' | sed 's/k8s/k8s-zookeeper/')
    pass="$(ssmget $cluster)"
    for server in $(n2ip "${key}-*" | clm 1); do
      open -a Firefox "https://exhibitor:${pass}@${server}/exhibitor/v1/ui/index.html"
    done
    printf 'SERVER=_ https://exhibitor:%s@$SERVER/exhibitor/v1/ui/index.html\n' $pass
  done
}

tf-purge () {
  for lock in $(find $INFRA_HOME/services -name '.terraform.lock.hcl'); do rm $lock; done
  for dir in $(find $INFRA_HOME -type d -name '.terraform'); do rm -rf $dir; done
}

kn () {
  kubectl get ns | cut -d ' ' -f1 | fzf | xargs kubectl config set-context --current --namespace
}

colocated-pods() {
  if [ -z "$1" ]; then
    echo "Usage: colocated-pods <pod-name>"
    return 1
  fi

  POD_NAME="$1"
  NODE_NAME=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

  if [ -z "$NODE_NAME" ]; then
    echo "Pod '$POD_NAME' not found."
    return 1
  fi

  echo "Node: $NODE_NAME"
  echo "Pods on the same node (Namespace | Pod Name | Status | Restarts | CPU | Memory):"

  # Get pods on the same node with status and restart count
  POD_INFO=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$NODE_NAME" -o custom-columns="NAMESPACE:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount" --no-headers)

  # Get resource usage (CPU and Memory) using kubectl top
  RESOURCE_USAGE=$(kubectl top pod --all-namespaces --no-headers | awk '{print $1,$2,$3,$4}')

  # Merge pod info with resource usage
  while IFS= read -r line; do
    POD_NAME=$(echo "$line" | awk '{print $2}')
    RESOURCES=$(echo "$RESOURCE_USAGE" | grep -w "$POD_NAME" | awk '{print $3, $4}')
    echo "$line $RESOURCES"
  done <<< "$POD_INFO"
}

s3-lookup() {
    # List all buckets and let the user select one with fzf
    bucket=$(aws s3 ls | awk '{print $3}' | fzf --prompt="Select S3 Bucket: ")

    if [[ -z "$bucket" ]]; then
        echo "No bucket selected."
        return 1
    fi

    # List objects in the selected bucket and search with fzf
    object=$(aws s3 ls "s3://$bucket" --recursive --human-readable --summarize | \
        awk '{$1=$2=""; print substr($0,3)}' | \
        fzf --prompt="Select S3 Object: ")

    if [[ -z "$object" ]]; then
        echo "No object selected."
        return 1
    fi

    # Fetch and display object properties
    echo -e "\nFetching properties for: $object\n"
    aws s3api head-object --bucket "$bucket" --key "$object" --output json
}

### ALIASES ###
alias al="aws sso login"
alias zshconfig="e ~/.zshrc"
alias rand="openssl rand -base64 25"
alias k="kubectl"
alias tfi="terraform init -backend-config=state.conf"
alias tfp="terraform plan"
alias tfa="terraform apply"
alias tfmt="terraform fmt"
alias tf="terraform"
alias 2.="cd ../../"
alias 3.="cd ../../../"
alias 4.="cd ../../../../"
alias 5.="cd ../../../../../"
alias argo="argo -n argo"
alias ccat="bat"
alias kc="kubectl config get-contexts -oname | fzf | xargs kubectl config use-context"
alias kcc="kubectl config current-context"
alias kgc="kubectl config get-contexts"
alias kmon="kubectl -n monitoring"
alias kdata="kubectl -n datasci"
alias ksys="kubectl -n kube-system"
alias kdaj="kubectl -n dajoku"
alias kargo="kubectl -n argo"
alias ksec="kubectl -n security"
alias ksolr="kubectl -n solr"
alias kgp="kubectl get pods"
alias kgd="kubectl get deployments"
alias cdinf="cd ~/code/infrastructure"
alias gri="git rebase --interactive"
alias gpf="git push --force-with-lease"
alias tfsl="terraform state list"
alias tfss="terraform state show"
alias gci="git branch | fzf | xargs git checkout"
alias gpm="git pull origin master"
alias gds="git diff --staged"
alias awsconfig="cat ~/.aws/config"
alias gs="git status"
alias grst="git restore --staged"
alias zource="source ~/.zshrc"
alias provider-env="source tf-provider-credentials"
alias dj="dajoku"
alias djl="BUNDLE_GEMFILE=~/code/dajoku_cli/Gemfile bundle exec ruby -I ~/code/dajoku_cli/lib ~/code/dajoku_cli/bin/dajoku"
alias dj-test-db="RACK_ENV=test RAILS_ENV=test bundle exec rake -t db:test:load db:seed"
alias p10kconfig="vim ~/.p10k.zsh"
alias e="code"
alias unpin="tf-sourcerer unpin"
alias repin="tf-sourcerer repin"
alias glog="git log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(bold yellow)%d%C(reset)%n'' %C(white)%s%C(reset) %C(dim white)- %an%C(reset)' --all"
alias tf-clean="rm -rf .terraform && rm .terraform.lock.hcl"
alias sdiff="csdiff"
alias diff="/opt/homebrew/bin/diff --color"
alias linters="~/code/infrastructure/.git/hooks/linters"
alias ssmc="ssmconnect"
alias ldacd="lotus dashboard argocd"
alias amtool-k8s="kmon exec -it alertmanager-prometheus-alertmanager-0 -- amtool --alertmanager.url=http://localhost:9093/"
alias mywf="argo list | grep patrick.lewis"
alias problem-pods="k get po --all-namespaces | grep -v Running | grep -v Completed"
alias ls="ls --color=auto"
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

. /opt/homebrew/opt/asdf/libexec/asdf.sh
source <(lotus completion zsh)
### MANAGED BY RANCHER DESKTOP START (DO NOT EDIT)
export PATH="/Users/patrick.lewis/.rd/bin:$PATH"
### MANAGED BY RANCHER DESKTOP END (DO NOT EDIT)
eval "$(nodenv init -)"
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
export PATH="$HOMEBREW_PREFIX/opt/libpq@16/bin:$PATH"

function tf-diff() {
  setopt LOCAL_OPTIONS NO_XTRACE 2>/dev/null
  local plan_file target_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -target=*)
        target_args+=("$1")
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  plan_file="${1:-tfplan}"
  local before_file after_file
  before_file=$(mktemp)
  after_file=$(mktemp)

  echo "Running terraform plan..."
  terraform plan "${target_args[@]}" -out="$plan_file"

  echo ""
  local changes
  changes=$(terraform show -json "$plan_file" | jq -c '.resource_changes[] | select(.change.actions != ["no-op"])')

  if [[ -z "$changes" ]]; then
    echo "No changes."
    return
  fi

  while IFS= read -r change; do
    echo ""
    printf $'\033[1;97;44m === %s (%s) ===\033[0m\n' \
      "$(echo "$change" | jq -r '.address')" \
      "$(echo "$change" | jq -r '.change.actions | join(", ")')"

    # Build sensitive-only views — output {} (not null) so diff shows clean +/- lines
    echo "$change" | jq '
      .change as $c | ($c.before_sensitive // {}) as $bs |
      if ($c.before == null) then {}
      elif (($bs | type) == "boolean" and $bs) then $c.before
      elif (($bs | type) == "object" and ($bs | length) > 0) then
        $c.before | with_entries(select(.key as $k | ($bs | has($k)) and ($bs[$k] | (type == "boolean" and .) or (type == "object" and length > 0))))
      else {} end
    ' > "$before_file"

    echo "$change" | jq '
      .change as $c | ($c.after_sensitive // {}) as $as |
      if ($c.after == null) then {}
      elif (($as | type) == "boolean" and $as) then $c.after
      elif (($as | type) == "object" and ($as | length) > 0) then
        $c.after | with_entries(select(.key as $k | ($as | has($k)) and ($as[$k] | (type == "boolean" and .) or (type == "object" and length > 0))))
      else {} end
    ' > "$after_file"

    # Show sensitive side-by-side diff only if files actually differ
    local cols half
    cols=$(tput cols)
    half=$(( (cols - 3) / 2 ))
    if ! command diff -q "$before_file" "$after_file" > /dev/null 2>&1; then
      printf $'\033[1;33m%-*s   %-*s\033[0m\n' "$half" "◀ BEFORE (sensitive)" "$half" "AFTER ▶"
      printf $'\033[2m%s\033[0m\n' "$(printf '─%.0s' $(seq 1 $cols))"
      command sdiff -w "$cols" "$before_file" "$after_file" | sed \
        -e $'s/<$/<  (deleted)/' \
        -e $'s/.*<  (deleted)$/\033[1;97;41m&\033[0m/' \
        -e $'s/^ *>.*$/\033[1;97;42m&\033[0m/' \
        -e $'s/.*|.*$/\033[1;30;43m&\033[0m/'
    fi

    # Summarize non-sensitive changed keys (visible in normal plan output)
    echo "$change" | jq -r '
      .change as $c |
      ($c.before_sensitive // {}) as $bs |
      ($c.after_sensitive // {}) as $as |
      [
        ((($c.before // {}) | keys) + (($c.after // {}) | keys)) | unique[] |
        select(
          . as $k |
          ($c.before[$k] != $c.after[$k]) and
          ((($bs | type) == "boolean" and $bs) or ($bs[$k] // false | (type == "boolean" and .) or (type == "object" and length > 0)) | not) and
          ((($as | type) == "boolean" and $as) or ($as[$k] // false | (type == "boolean" and .) or (type == "object" and length > 0)) | not)
        )
      ] | if length > 0 then "CHANGED (see plan): \(join(", "))" else empty end
    ' | sed $'s/.*/\033[2m&\033[0m/'

  done <<< "$changes"
  rm -f "$before_file" "$after_file"
}
