#!/bin/bash
set -e
# Partly copy from vg's benchmark script (https://github.com/vgteam/vg/blob/master/scripts/map-sim)

#sudo docker pull quay.io/vgteam/vg:v1.12.1
#alias dockervg="sudo docker run quay.io/vgteam/vg:v1.12.1 vg"
    #sudo docker run quay.io/vgteam/vg:v1.12.1 vg "$@"
#}

if [ $# -ne 19 ];
then
    echo "usage: "$(basename $0) "[output-dir] [fasta-ref] [vg-ref] [vg-pan] [hap0-base] [hap1-base] [sim-base] [sim-ref] [threads] [sim-read-spec] [sim-seed] [bp-threshold] [vg-map-opts]"
    echo "example: "$(basename $0) 'SGRP2/SGD_2010.fasta SGRP2/SGRP2-cerevisiae.pathonly SGRP2/SGRP2-cerevisiae SGRP2/SGRP2-cerevisiae BC187-haps0 BC187-haps1 BC187 BC187.ref 4 "-n 50000 -e 0.01 -i 0.002 -l 150 -p 500 -v 50" 27 150 "-u 16"'
    exit
fi

output=$1
fasta=$2
ref=$3
pan=$4
haps1=$5
haps2=$6
sim=$7
sim_ref=$8
threads=$9
read_spec=${10}
seed=${11}
threshold=${12}
vg_map_opts=${13}
obg_graph_dir=${14}
chromosomes=${15}
simulation_ob_graph=${16}
simulation_ob_reference_path=${17}
graph_vcf_file=${18}
simulation_vcf_file=${19}

pan_xg=$pan.xg
pan_gcsa=$pan.gcsa
ref_xg=$ref.xg
ref_gcsa=$ref.gcsa
haps1_xg=$haps1.xg
haps2_xg=$haps2.xg
sim_xg=$sim.xg
sim_ref_xg=$sim_ref.xg
vg_scripts_dir=/home/ivar/dev/vg/scripts/

echo $sim_xg $ref_xg $pan_xg

mkdir -p $output

# Get the vg id
id=$(vg version | cut -f 3 -d- | tail -c 8 | head -c 7)

# generate the simulated reads if we haven't already
if [ ! -e sim.gam.truth.tsv ];
then
    echo generating simulated reads
    vg sim $read_spec -s $seed -x $haps1_xg -a >sim1.gam &
    vg sim $read_spec -s $(echo "$seed + 1" | bc) -x $haps2_xg -a >sim2.gam &
    wait
    cat sim1.gam sim2.gam >sim.gam

    rm -f sim1.gam sim2.gam
    vg annotate -p -x $sim_xg -a sim.gam | vg view -a - | jq -c -r '[ .name, .refpos[0].name, .refpos[0].offset ] | @tsv' | sort >truth.tsv
    vg annotate -n -x $sim_ref_xg -a sim.gam | tail -n+2 | sort >novelty.tsv
    # Find out which reads cover rare variants
    python3 ../find_rare_variants.py $simulation_ob_graph sim.json $simulation_ob_reference_path $graph_vcf_file $simulation_vcf_file | sort > rare_variants.pos

    join truth.tsv novelty.tsv | join - rare_variants.pos > sim.gam.truth.tsv
    exit
    # split the file into the mates
    vg view -X sim.gam | gzip >sim.fq.gz &
    vg view -a sim.gam | jq -cr 'select(.name | test("_1$"))' | vg view -JaG - | vg view -X - | sed s/_1$// | gzip >sim_1.fq.gz &
    vg view -a sim.gam | jq -cr 'select(.name | test("_2$"))' | vg view -JaG - | vg view -X - | sed s/_2$// | gzip >sim_2.fq.gz &
    wait

    # Convert fq to fasta, neede for hybrid aligner
    gunzip -c sim.fq.gz > sim.fq
    #fastq_to_fasta -i sim.fq -o sim.fa
    paste - - - - < sim.fq | cut -f 1,2 | sed 's/^@/>/' | tr "\t" "\n" > sim.fa

fi

# Map these simulated reads in three different ways:

# 1) Two step mapper
#chromosomes="1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,X"
# Map the two different ways
rough_graph_mapper map_linear_to_graph --skip-mapq-adjustment True -t 70 -r $fasta -f sim.fa -d $obg_graph_dir -c $chromosomes -o linear_to_graph_mapped.graphalignments
rough_graph_mapper traversemapper -s True -t 70 -r $fasta -f sim.fa -d $obg_graph_dir -c $chromosomes -o traversemapped.graphalignments

# Filter
rough_graph_mapper filter --min-mapq 50 -a traversemapped.graphalignments > traversemapped.filtered.graphalignments

two_step_graph_mapper predict_path -t $threads -d $obg_graph_dir -a traversemapped.filtered.graphalignments -c $chromosomes -o predicted_path_traversemapped
two_step_graph_mapper predict_path -t $threads -d $obg_graph_dir -a linear_to_graph_mapped.graphalignments -c $chromosomes -o predicted_path

# Map to path by using linear to graph mapped path
two_step_graph_mapper map_to_path -t $threads -r predicted_path.fa -f sim.fa -o two_step_graph_mapper.sam

# Use traversemapped path
two_step_graph_mapper map_to_path -t $threads -r predicted_path_traversemapped.fa -f sim.fa -o two_step_graph_mapper_traversemapped.sam

# Convert to linear pos
two_step_graph_mapper convert_to_reference_positions -s two_step_graph_mapper.sam -d $obg_graph_dir/ -l predicted_path -c $chromosomes -o two_step_graph_mapper_on_reference.sam
awk '$2!=2048 && $2 != 2064' two_step_graph_mapper_on_reference.sam | grep -v ^@ | awk -v OFS="\t" '{$4=($4 + 0); print}' | cut -f 1,3,4,5,14 | sed s/AS:i:// | sort >two_step_graph_mapper.pos
join two_step_graph_mapper.pos sim.gam.truth.tsv | ../vg_sim_pos_compare.py $threshold >two_step_graph_mapper.compare

two_step_graph_mapper convert_to_reference_positions -s two_step_graph_mapper_traversemapped.sam -d $obg_graph_dir/ -l predicted_path_traversemapped -c $chromosomes -o two_step_graph_mapper_on_reference_traversemapped.sam
awk '$2!=2048 && $2 != 2064' two_step_graph_mapper_on_reference_traversemapped.sam | grep -v ^@ | awk -v OFS="\t" '{$4=($4 + 0); print}' | cut -f 1,3,4,5,14 | sed s/AS:i:// | sort >two_step_graph_mapper_traversemapped.pos
join two_step_graph_mapper_traversemapped.pos sim.gam.truth.tsv | ../vg_sim_pos_compare.py $threshold >two_step_graph_mapper_traversemapped.compare

# 2) Normal linear mapping
two_step_graph_mapper map_to_path -t $threads -r $fasta -f sim.fa -o bwa.sam
awk '$2!=2048 && $2 != 2064' bwa.sam | grep -v ^@ | awk -v OFS="\t" '{$4=($4 + 0); print}' | cut -f 1,3,4,5,14 | sed s/AS:i:// | sort >bwa.pos
join bwa.pos sim.gam.truth.tsv | ../vg_sim_pos_compare.py $threshold >bwa.compare

# Seven bridges
awk '$2!=2048 && $2 != 2064' seven_bridges.sam | grep -v ^@ | awk -v OFS="\t" '{$4=($4 + 0); print}' | cut -f 1,3,4,5,14 | sed s/AS:i:// | sort > seven_bridges.pos
join seven_bridges.pos sim.gam.truth.tsv | ../vg_sim_pos_compare.py $threshold >seven_bridges.compare


# 3) vg
#echo "vg pan single mappping"
#time vg map $vg_map_opts -G sim.gam -x $pan_xg -g $pan_gcsa -t $threads --refpos-table | sort  > vg-pan-se.pos
#join vg-pan-se.pos sim.gam.truth.tsv | ../vg_sim_pos_compare.py $threshold >vg-pan-se.compare

#../create_roc_plots.sh
