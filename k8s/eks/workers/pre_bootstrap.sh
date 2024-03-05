#!/bin/bash

set -o errexit -o nounset -o pipefail

GIT_HELPER_BASE=$1

s5cmd_base_download_url="https://github.com/peak/s5cmd/releases/download/v2.2.2/"
s5cmd_arm64_file="s5cmd_2.2.2_Linux-arm64.tar.gz"
s5cmd_x64_file="s5cmd_2.2.2_Linux-64bit.tar.gz"

function preload_containerd() {
    local start_time=$(date +%s)

    ec2_instance=$(ec2-metadata -i | cut -d ' ' -f2)

    # Step 1: Fetch label value and handle missing label
    bucket_name=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${ec2_instance}" "Name=key,Values=k8s.warpbuild.com/image-bucket-name" --output text | cut -f5)
    if [[ -z "$bucket_name" ]]; then
        echo "Node does not have the 'preload-image-bucket-name' label. Skipping preloading."
        return 0  # Exit successfully
    fi

    node_ami_id=$(aws ec2 describe-instances --instance-ids "${ec2_instance}" --query 'Reservations[0].Instances[0].ImageId' --output text)
    node_image_name_major=$(aws ec2 describe-images --image-ids "${node_ami_id}" --query 'Images[0].Name' --output text | sed 's/-v.*$//')
    # node_image_name_major="amazon-eks-amd64-node-1.27"

    if [[ -z "$node_image_name_major" ]]; then
        echo "failed to parse node image name, skipping the image preload"
        return 0
    fi

    s5cmd_download_url=""
    s5cmd_download_file=""
    # Step 2: Determine node architecture using if-else
    node_arch=$(uname -m)
    if [[ "$node_arch" == "x86_64" || "$node_arch" == "AMD64" ]]; then
        node_arch="x64"
        s5cmd_download_url="${s5cmd_base_download_url}${s5cmd_x64_file}"
        s5cmd_download_file="${s5cmd_x64_file}"
    elif [[ "$node_arch" == "aarch64" ]]; then
        node_arch="arm64"
        s5cmd_download_url="${s5cmd_base_download_url}${s5cmd_arm64_file}"
        s5cmd_download_file="${s5cmd_arm64_file}"
    else
        echo "Unsupported architecture: $node_arch. Skipping preloading."
        return 0  # Exit with error
    fi

    echo "arch :  ${node_arch} bucket : ${bucket_name} ami_major : ${node_image_name_major}"

    # Step 3: Check and create containerd directory
    mkdir -p "/mnt/k8s-disks/0/containerd" && chmod 777 "/mnt/k8s-disks/0/containerd"


    # Step 4-7: Download, install, and move s5cmd
    mkdir -p /mnt/k8s-disks/0/s5cmd && cd /mnt/k8s-disks/0/s5cmd
    wget $s5cmd_download_url
    tar -xf $s5cmd_download_file
    chmod +x s5cmd && mv s5cmd /usr/bin/

    cd /mnt/k8s-disks/0

    # Log disk usage
    disk_usage=$(du -h /mnt/k8s-disks/0/)
    echo "\n Pre Load Disk usage: ${disk_usage}"

    tag_to_load=""
    s5cmd_concurrency=128
    s5cmd_part_size=500

    arch_config_file="$GIT_HELPER_BASE/$node_arch/config.json"
    # Check if the JSON file exists
    if [[ ! -f "$arch_config_file" ]]; then
        echo "Error: JSON file '$arch_config_file' does not exist or is not a regular file."
        return 0
    else
        tag_to_load=$(cat $arch_config_file | jq -r '.node_image."'$node_image_name_major'".tag')
        s5cmd_concurrency=$(cat $arch_config_file | jq -r '.["'s5cmd'"].concurrency')
        s5cmd_part_size=$(cat $arch_config_file | jq -r '.["'s5cmd'"].part_size')
    fi

    if [[ -z "$tag_to_load" ]]; then
        echo "Missing 'tag' key in 'config.json' or empty value for ${node_image_name_major}"
        return 0  # Exit successfully
    fi

    echo "Found 'tag' key in 'config.json' : ${tag_to_load}"

    containerd_stopped=false

    # Step 8: Stop containerd (if running)
    if systemctl is-active --quiet containerd; then
        echo "Stopping containerd..."
        systemctl stop --now containerd && containerd_stopped=true
    fi

    cd /mnt/k8s-disks/0

    #remove all existing contents from containerd directory before copying from s3
    rm -rf ./containerd/*

    download_failed=false

    # Step 9: Copy content from S3 using s5cmd
    s5cmd cp -c $s5cmd_concurrency -p $s5cmd_part_size "s3://${bucket_name}/${node_arch}/${tag_to_load}/containerd/*" ./containerd/ || download_failed=true
    if [[ $download_failed == true ]]; then
        echo "Error: download containerd images failed, removing all contents from the containerd directory to restore to blank state"
        rm -rf ./containerd/*
    fi

    # Step 10: Start containerd (only if stopped in step 8)
    if [[ $containerd_stopped == true ]]; then
        echo "Starting containerd..."
        systemctl start --now containerd
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo "Preload containerd completed in $elapsed seconds"
}

function limit_max_pods() {
# This number should not exceed max instance storage on node (pods * storage per pod)
MAX_PODS=50
# EKS Managed Nodes which use Amazon AMIs run /etc/eks/bootstrap.sh to bootstrap an instance into EKS cluster. Ref: https://github.com/awslabs/amazon-eks-ami/blob/master/files/bootstrap.sh
# The user data the we provide to AWS is prepended to the content of this script. Because of this, the env vars that we provide are usually overwritten at the end by the default values in /etc/eks/bootstrap.sh
# To limit the number of pods per node, we overwrite the KUBELET_EXTRA_ARGS variable in /etc/eks/bootstrap.sh to include/replace the --max-pods flag with the desired value.
# Ref for the script: https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2551#issuecomment-1534954523
LINE_NUMBER=$(grep -n "KUBELET_EXTRA_ARGS=\$2" /etc/eks/bootstrap.sh | cut -f1 -d:)
    if [ -n "$LINE_NUMBER" ]; then
        REPLACEMENT="\ \ \ \ \ \ KUBELET_EXTRA_ARGS=\$(echo \$2 | sed -s -E 's/--max-pods=[0-9]+/--max-pods=$MAX_PODS/g')"
        sed -i '/KUBELET_EXTRA_ARGS=\$2/d' /etc/eks/bootstrap.sh
        sed -i "${LINE_NUMBER}i ${REPLACEMENT}" /etc/eks/bootstrap.sh
    else
        echo "Line number not found, skipping max nodes config"
    fi
}

preload_containerd
limit_max_pods