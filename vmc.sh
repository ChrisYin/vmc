#!/bin/bash

# Prerequisite

## prevent wildcard expansion
set -o noglob


# glbal variable
# ip: vm's ip address
# pci: vm's pci device
# hda: vm's qcow2 image path
# vcpu: vm's vcpu count
# vmlist: current vm's list

# library

## get vm ip from vm's name
## $1: vm's name
_get_vm_ip ()
{
        ip=$(virsh domifaddr "$1" | sed '1,2d' | awk '{print $4}')
        ip=${ip%/*}
}

## get vm pci dbsf from vm's name
## $1: vm's name
_get_vm_pci ()
{
        local xml dbsf
        xml=$(virsh dumpxml "$1" | xmllint --xpath "//domain/devices/hostdev/source/address" - 2> /dev/null)
        if [ -z "$xml" ]; then
                pci="no device"
                return 0
        fi
        dbsf=$(echo "$xml" |  awk -F'[=/< "]' '{print $5 " " $9 " " $13 " " $17}')
        pci=$(echo "$dbsf" |  awk -F'[x ]' '{print $2":"$4":"$6"."$8}')
}

## get vm qcow2 image path from vm's name
## $1: vm's name
_get_vm_hda ()
{
        hda=$(virsh domblklist "$1" | grep hda | awk '{print $2}')
        if [ -z "$hda" ]; then
                hda=""
                return 0
        fi
        if [ ! -f "$hda" ]; then
                hda=""
                return 0
        fi
}

## get vm vcpu from vm's name
## $1: vm's name
_get_vm_vcpu ()
{
        local xml dbsf
        vcpu=$(virsh vcpucount "$1" | grep "current" | grep "config" | awk '{print $3}')
}

## wrap the fuzzy find and grep, used only when matching single result
## $1: string to find from
## $2: string to match
## $3: disable fzf
_finder_wrapper()
{
        local results=""
        local result=""
        if [ -n "$2" ]; then
                results=$(echo "$1" | grep -E  "$2")
                if [ 1 -eq $(echo "$results" | wc -l) ]; then
                        result=$results
                else
                        select result in $results; do
                                break
                        done
                fi
        fi
        echo "$result"
}

## match vm list
## $1   vm's name
## $2:  single -> match single vm
##      default -> match multi vm
_match_vmlist()
{
        # matching string end with *
        if [[ "$1" =~ [*\*$] ]];
        then
                local key=${1%\*}
                # matching string start with key
                vmlist=$(echo "$vmlist" | grep -E "^$key")
        else
                if [ 0 -eq "$(echo "$1" | grep -cEi "[a-zA-Z]+")" ] && [ -n "$1" ]; then
                        if [ "$2" == "single" ]; then
                                vmlist=$(echo "$vmlist" | grep -E "vats-test.*-$(printf "%02d" "$1")")
                        else
                                local arr=()
                                for i in $(seq 1 "$1");
                                do
                                        local tmp=$(echo "$vmlist" | grep -E "vats-test.*-$(printf "%02d" "$i")")
                                        echo "$tmp"
                                        arr+=("$tmp")
                                done
                                oldIFS=$IFS
                                IFS=$(echo -e "\n\r")
                                vmlist="${arr[*]}"
                                IFS=$oldIFS
                        fi
                else
                        vmlist=$(_finder_wrapper  "$vmlist" "$1")
                fi
        fi
}

# shell body

## list information of virtual machine
## $1: -v: verbose list
_list_vm()
{
        local name state
        vmlist=$(virsh list --all | sed '1,2d')
        if [ "$1" == "-v" ];
        then
                indent_num=$(expr 50 + 10 + 20 + 15 + 10 + 4)
                printf "%-50s %-10s %-20s %-15s %-10s\n" "NAME" "STATE" "IP ADDRESS" "PCI DEVICE" "VCPU_NUM"
        else
                indent_num=$(expr 50 + 10 + 20 + 2)
                printf "%-50s %-10s %-20s\n" "NAME" "STATE" "IP ADDRESS"
        fi
        for i in $(seq 1 $indent_num); do
                printf "="
        done
        printf "\n"
        while read -r vminfo; do
                name=$(echo "$vminfo" | awk '{print $2}')
                state=$(echo "$vminfo" | awk '{print $3}')
                if [ "$state" == "running" ];
                then
                        state="running"
                        _get_vm_ip "$name"
                        if [ -z "$ip" ];
                        then ip="none"
                        fi
                else
                        state="stop"
                        ip="none"
                fi
                if [ "$1" == "-v" ];
                then
                        _get_vm_pci "$name"
                        _get_vm_vcpu "$name"
                        printf "%-50s %-10s %-20s %-15s %-10s\n" "$name" "$state" "$ip" "$pci" "$vcpu"
                else
                        printf "%-50s %-10s %-20s\n" "$name" "$state" "$ip"
                fi
        done <<< "$vmlist"
}

## connect virtual machine
## $1: vm's name
_connect_vm()
{
        local state
        vmlist=$(virsh list --name)
        _match_vmlist "$1" "single"
        if [ -z "$vmlist" ]; then
                echo "no matched vm"
                return 1
        fi
        state=$(virsh domstate "$vmlist")
        if [ "$state" == "running" ];
        then
                ip=""
                while [ -z "$ip" ]
                do
                        sleep 1
                        _get_vm_ip "$vmlist"
                done
                until nc -vzw 2 "$ip" 22; do sleep 2; done
                sshpass -p amd1234 ssh -o StrictHostKeyChecking=no root@"$ip"
        else
                echo "VM is not running"
        fi
}

## start virtual machine
## $1: vm's name
_start_vm()
{
        vmlist=$(virsh list --name --all)
        _match_vmlist "$1"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
        else
                while read -r vm; do
                        echo "starting $vm"
                        virsh start "$vm"
                done <<< "$vmlist"
        fi
}

## destroy virtual machine
## $1: vm's name
_destroy_vm()
{
        vmlist=$(virsh list --name)
        _match_vmlist "$1"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
        else
                while read -r vm; do
                        echo "destroying $vm"
                        virsh destroy "$vm"
                done <<< "$vmlist"
        fi
}

## connect to vm console
## $1: vm's name
_connect_vm_console()
{
        local state
        vmlist=$(virsh list --name)
        _match_vmlist "$1" "single"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
                return 1
        fi
        state=$(virsh domstate "$vmlist")
        if [ "$state" == "running" ];
        then
                ip=""
                while [ -z "$ip" ]
                do
                        sleep 1
                        _get_vm_ip "$vmlist"
                done
                until nc -vzw 2 "$ip" 22; do sleep 2; done
                virsh console "$vmlist" --force
        else
                echo "VM is not running"
        fi
}

## change attached vf device
## $1: vm's name
## $2: pci dbsf
_change_dev()
{
        vmlist=$(virsh list --name --all)
        _match_vmlist "$1" "single"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
                return 1
        fi
        _get_vm_pci "$vmlist"
        echo current device attached to "$vmlist": "$pci"

        virt-xml "$vmlist" --remove-device --host-dev all
        pci=$( _finder_wrapper  "$(lspci -D| grep ATI | grep Display)" "$2")
        if [ -n "$pci" ]; then
                virt-xml "$vmlist" --add-device --host-dev "$(echo "$pci" | awk -F " " '{print $1}')"
        else
                echo no pci-device attached
        fi
}

## change attached vcpu number
## $1: vm's name
## $2: vcpu number
_change_vcpu()
{
        vmlist=$(virsh list --name --all)
        _match_vmlist "$1" "single"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
                return 1
        fi
        virt-xml "$vmlist" --edit --vcpus "$2"
        echo "$vmlist vcpu changed to $2"
}

## clone vm from base vm
## $1: base vm's name
## $2: child vm's name
_clone_vm()
{
        local backing_file hda_dir
        if [ $# != 2 ];
        then
                echo "Please give name of base vm and child vm"
                return 1
        fi
        vmlist=$(virsh list --name --all)
        _match_vmlist "$1" "single"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
                return 1
        fi
        _get_vm_hda "$vmlist"
        if [ ! -f "$hda" ];
        then
                echo "Error path of hda"
                return 1
        fi
        #echo "$hda"
        backing_file=$(qemu-img info "$hda" | grep "backing file:" | awk '{print $3}')
        #echo "$backing_file"
        if [[ -n "$backing_file" ]];
        then
                echo "$vmlist is a child vm, please be carefull during clone"
        fi
        echo "clone VM from $vmlist to $2"
        hda_dir=$(dirname "$hda")
        qemu-img create -f qcow2 -F qcow2 -b "$hda" "$hda_dir/$2.qcow2"
        virt-clone --original "$vmlist" --name "$2" --file "$hda_dir/$2.qcow2" --preserve-data
        return 0
}

## copy vm from child vm
## $1: old child vm's name
## $2: new child vm's name
_copy_vm()
{
        local backing_file hda_dir
        if [ $# != 2 ];
        then
                echo "Please give name of old child vm and new child vm"
                return 1
        fi
        vmlist=$(virsh list --name --all)
        _match_vmlist "$1" "single"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
                return 1
        fi
        if [ "$vmlist" == "$2" ];
        then
                echo "Same name for child and parent VM!"
                return 1
        fi
        _get_vm_hda "$vmlist"
        if [ ! -f "$hda" ];
        then
                echo "Error path of hda"
                return 1
        fi
        #echo "$hda"
        backing_file=$(qemu-img info "$hda" | grep "backing file:" | awk '{print $3}')
        #echo "$backing_file"
        if [[ -z "$backing_file" ]];
        then
                echo "$vmlist is a base vm, do not support copy"
                return 1
        fi
        echo "copy VM from $vmlist to $2"
        hda_dir=$(dirname "$hda")
        cp "$hda" "$hda_dir/$2.qcow2"
        virt-clone --original "$vmlist" --name "$2" --file "$hda_dir/$2.qcow2" --preserve-data
        return 0
}

## delete vm
## $1: vm's name
_delete_vm()
{
        if [ "$2" == "-a" ];
        then
                vmlist=$(virsh list --name --all)
                _match_vmlist "$1" "single"
                if [ -z "$vmlist" ];
                then
                        echo "no matched vm"
                        return 1
                fi
                _get_vm_hda "$vmlist"
                if [ ! -f "$hda" ];
                then
                        echo "Error path of hda"
                        return 1
                fi
                echo "Delete $hda"
                rm "$hda"
        fi
        virsh undefine "$1"
}

## reset virtual machine
## $1: vm's name
_reset_vm()
{
        vmlist=$(virsh list --name)
        _match_vmlist "$1"
        if [ -z "$vmlist" ];
        then
                echo "no matched vm"
        else
                while read -r vm; do
                        echo "reseting $vm"
                        virsh reset "$vm"
                done <<< "$vmlist"
        fi
}

_help()
{
        case $1 in
        "--help"| "-h")
                echo "vmc <command> [args]"
                echo ""
                echo "commands:"
                echo ""
                printf "%-20s %-60s\n" "list" "list all virtual machines"
                printf "%-20s %-60s\n" "start" "start one/multi virtual machines according to pattern"
                printf "%-20s %-60s\n" "connect" "connect one virtual machine via ssh according to pattern"
                printf "%-20s %-60s\n" "destroy" "destroy one/multi virtual machines according to pattern"
                printf "%-20s %-60s\n" "console" "connect one virtual machine via console according to pattern"
                printf "%-20s %-60s\n" "change-dev" "change the vf attached to the virtual machine"
                printf "%-20s %-60s\n" "change-vcpu" "change the vcpu number attached to the virtual machine"
                printf "%-20s %-60s\n" "clone" "clone a child virtual machine from the base virtual machine"
                printf "%-20s %-60s\n" "copy" "copy a new child virtual machine from old child virtual machine"
                printf "%-20s %-60s\n" "delete" "delete(undefine) a virtual machine"
                printf "%-20s %-60s\n" "reset" "reset one/multi virtual machines according to pattern"
                printf "%-20s %-60s\n" "--help" "show this help document"
                echo ""
                echo "use vmc <command> --help to get detailed help"
                ;;
        "list")
                echo "NAME"
                echo "vmc list - list all virtual machines"
                echo ""
                echo "SYNOPSIS"
                echo "vmc list [-v]"
                echo ""
                echo "DESCRIPTION"
                echo "list all virtual machines' name, state and ip"
                echo ""
                echo "OPTION"
                printf "%-20s %-60s\n" "-v" "show the vf device attached to the virtual machine"
                ;;
        "start")
                echo "NAME"
                echo "vmc start - start one/multi virtual machines according to pattern"
                echo ""
                echo "SYNOPSIS"
                echo "vmc start <domain_name>           automatically start the VM"
                echo "vmc start <num>                   automatically start the VM that matches vats-test.*-xx"
                echo "vmc start <pattern>               automatically start the VM that starts with the pattern"
                echo ""
                ;;
        "destroy")
                echo "NAME"
                echo "vmc destroy - destroy one/multi virtual machines according to pattern"
                echo ""
                echo "SYNOPSIS"
                echo "vmc destroy <domain_name>           automatically destroy the VM"
                echo "vmc destroy <num>                   automatically destroy the VM that matches vats-test.*-xx"
                echo "vmc destroy <pattern>               automatically destroy the VM that destroys with the pattern"
                echo ""
                ;;
        "connect")
                echo "NAME"
                echo "vmc connect - connect one virtual machine via ssh according to pattern"
                echo ""
                echo "SYNOPSIS"
                echo "vmc connect <domain_name>           connect to the specific vm via ssh"
                echo "vmc connect <num>                   automatically connect the VM that matches vats-test.*-xx"
                echo ""
                ;;
        "console")
                echo "NAME"
                echo "vmc console - connect one virtual machine via console according to pattern"
                echo ""
                echo "SYNOPSIS"
                echo "vmc console <domain_name>           connect to the specific vm via console"
                echo "vmc console <num>                   automatically connect the VM that matches vats-test.*-xx"
                echo ""
                ;;
        "change-dev")
                echo "NAME"
                echo "vmc change-dev - change the vf attached to the virtual machine"
                echo ""
                echo "SYNOPSIS"
                echo "vmc change-dev <domain_name> <pci_bdf>           change the specific vm to attach the specific device"
                echo "vmc change-dev <num> <pci_bdf>                   change the VM that matches vats-test.*-xx"
                echo ""
                ;;
        "change-vcpu")
                echo "NAME"
                echo "vmc change-vcpu - change the vcpu number attached to the virtual machine"
                echo ""
                echo "SYNOPSIS"
                echo "vmc change-vcpu <domain_name> <vcpu_num>           change the vcpu number of the specific VM"
                echo ""
                ;;
        "clone")
                echo "NAME"
                echo "vmc clone - clone a child virtual machine from the base virtual machine"
                echo ""
                echo "SYNOPSIS"
                echo "vmc clone <base_domain_name> <child_domain_name>           clone a child VM from the base VM"
                echo ""
                ;;
        "copy")
                echo "NAME"
                echo "vmc copy - copy a new child virtual machine from old child virtual machine"
                echo ""
                echo "SYNOPSIS"
                echo "vmc clone <old_child_domain_name> <new_child_domain_name>      clone a new VM from the child VM"
                echo ""
                ;;
        "delete")
                echo "NAME"
                echo "vmc delete - delete(undefine) a virtual machine"
                echo ""
                echo "SYNOPSIS"
                echo "vmc delete <domain_name>           delete(undefine) a VM"
                echo ""
                echo "OPTION"
                printf "%-20s %-60s\n" "-a" "delete virtual machine's qcow2 image"
                ;;
        "reset")
                echo "NAME"
                echo "vmc reset - reset one/multi virtual machines according to pattern"
                echo ""
                echo "SYNOPSIS"
                echo "vmc reset <domain_name>           automatically reset the VM"
                echo "vmc reset <num>                   automatically reset the VM that matches vats-test.*-xx"
                echo "vmc reset <pattern>               automatically reset the VM that resets with the pattern"
                ;;
        *)
                echo "command undefined! Please use vmc --help"
                ;;
        esac
}
## vmc: virtual machine controller
if [ "${*: -1}" == "--help" ] || [ "${*: -1}" == "-h" ]; then
        _help "$@"
        exit 0
fi

case $1 in
"list")
        shift
        _list_vm "$@"
        ;;
"start")
        shift
        _start_vm "$@"
        ;;
"connect")
        shift
        _connect_vm "$@"
        ;;
"destroy")
        shift
        _destroy_vm "$@"
        ;;
"console")
        shift
        _connect_vm_console "$@"
        ;;
"change-dev")
        shift
        _change_dev "$@"
        ;;
"change-vcpu")
        shift
        _change_vcpu "$@"
        ;;
"clone")
        shift
        _clone_vm "$@"
        ;;
"copy")
        shift
        _copy_vm "$@"
        ;;
"delete")
        shift
        _delete_vm "$@"
        ;;
"reset")
        shift
        _reset_vm "$@"
        ;;
*)
        echo "command undefined! Please use vmc --help"
esac

# clean and reset option

## restore wildcard expansion
set +o noglob
