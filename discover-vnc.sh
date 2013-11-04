#!/bin/bash

trap '{
	# this block gets called before exit
    if [ -z "$out" ]; then
        exit 0
    fi
    # some time consuming calulations might be done here
    printf "%s\n" "${out[@]}"
    echo "${#out[@]} host(s) found."
}' EXIT

out=(); i=0
while read -r line; do
    i=`expr $i + 1`
    if [ $i -lt 5 ]; then continue; fi # skip the header lines

	out+=("$line")

	# break if no more items will follow (e.g. Flags != 3)
	if [ $(echo $line | cut -d ' ' -f 3) -ne '3' ]; then
		break
	fi
done < <((sleep 0.5; kill -13 0) & # kill quickly if trapped
			dns-sd -B _rfb._tcp)

# kill child processes
kill -13 0
exit 0