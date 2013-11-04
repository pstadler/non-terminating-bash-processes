# Taming non-terminating Bash processes

A couple of months ago I found myself hacking on a sophisticated workflow for the brand new [Alfred 2](http://www.alfredapp.com/) - a powerful replacement for Spotlight on OS X. This major release enabled scripting support for populating Alfred's list of "search" results.

My goal was to make screen sharing with Alfred a quick and painless endeavor. The user would enter "vnc" to get a list of available hosts with VNC enabled to choose from. The workflow should run on every OS X device without installing any kind of 3rd party software and leaving no side-effects — a simple Bash script should be perfect.

That's when I entered the dark and scary world of non-terminating Bash processes.

## Discovering network services from the command line

Hunting for a way to discover network services from the command line, I ended up with a tool called `dns-sd`.

```
$ whatis dns-sd
dns-sd(1)            - Multicast DNS (mDNS) & DNS Service Discovery (DNS-SD) Test Tool
```

The [man page](https://developer.apple.com/library/mac/documentation/Darwin/Reference/ManPages/man1/dns-sd.1.html) revealed that `dns-sd -B type domain` will "browse for instances of service type in domain". After some research I figured out that the service type for VNC is *\_rfb.\_tcp*.

```
# /etc/services contains a list of service types mapped to ports and protocols:
$ cat /etc/services | grep vnc
rfb             5900/tcp    vnc-server # VNC Server
rfb             5900/udp    vnc-server # VNC Server
```

In case you're wondering, *rfb* stands for *remote frame buffer*. Running `dns-sd -B _rfb._tcp` and...

```
Browsing for _rfb._tcp
DATE: ---Mon 04 Nov 2013---
11:43:44.909  ...STARTING...
Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
11:43:44.910  Add        3   4 local.               _rfb._tcp.           Brainbug
11:43:44.910  Add        2   4 local.               _rfb._tcp.           Tesla
```

Bingo, that's it! 

## The never-ending loop

The problem is that `dns-sd -B` never terminates. It will continue to display changes in network services forever until you interrupt it (e.g Ctrl+c).

```
#!/bin/bash
while read -r line; do # trapped in the loop
	echo $line
done < <(dns-sd -B _rfb._tcp)

echo "This is never gonna be displayed."
```

We have to break out of the loop at some point. Digging a little bit further unveils that `dns-sd` will send a "3" in the "Flags" column if there's more to display (see output above). In any other case there will be a different value, so let's skip the header and check for the flag in the subsequent lines.

```
#!/bin/bash
i=0
while read -r line; do
    i=`expr $i + 1`
    if [ $i -lt 5 ]; then continue; fi # skip the header lines
    
	echo $line
	
	# break if no more items will follow (e.g. Flags != 3)
	if [ $(echo $line | cut -d ' ' -f 3) -ne '3' ]; then
		break
	fi
done < <(dns-sd -B _rfb._tcp)

echo "This _is_ displayed."
```

This breaks out of the loop but `dns-sd` continues to run in a subshell (`<(dns-sd -B _rfb._tcp)`) even if the parent process exits. If we don't kill it manually the process will run forever in the background.

## Kill the children

Nothing simpler than that. Let's just kill the child process before exiting the script.

```
#!/bin/bash
i=0
while read -r line; do
    i=`expr $i + 1`
    if [ $i -lt 5 ]; then continue; fi # skip the header lines
    
	echo $line
	
	# break if no more items will follow (e.g. Flags != 3)
	if [ $(echo $line | cut -d ' ' -f 3) -ne '3' ]; then
		break
	fi
done < <(dns-sd -B _rfb._tcp)

# kill child processes
kill -9 0 # SIGINT is not enough, let's send SIGKILL
```

Success! No more background processes after exit. However, there's this nasty problem with SIGKILL's verbose nature.

```
$ ./discover-vnc.sh # contains the code above
13:07:12.542 Add 3 4 local. _rfb._tcp. Brainbug
13:07:12.542 Add 2 4 local. _rfb._tcp. Tesla
[1]    58181 killed     ./foo.sh
```

It's crucial to suppress this line. Doing some research on the topic revealed the following:

> "If a pipeline in a shell script is killed by a signal other than SIGINT or SIGPIPE, the shell reports it. People generally want to know when their processes are killed. It's
independent of job control."
> — [Chet Ramey on the Bash mailing list](http://lists.gnu.org/archive/html/bug-bash/2006-09/msg00073.html)

SIGKILL is too verbose, SIGINT is too soft, let's hope that SIGPIPE (-13) will do the trick.

```
#!/bin/bash
i=0
while read -r line; do
    i=`expr $i + 1`
    if [ $i -lt 5 ]; then continue; fi # skip the header lines
    
	echo $line
	
	# break if no more items will follow (e.g. Flags != 3)
	if [ $(echo $line | cut -d ' ' -f 3) -ne '3' ]; then
		break
	fi
done < <(dns-sd -B _rfb._tcp)

# kill child processes
kill -13 0 # SIGPIPE to the rescue
```

It does the trick. The child process gets killed while the termination message is suppressed:

```
$ ./discover-vnc.sh # contains the code above
13:07:12.542 Add 3 4 local. _rfb._tcp. Brainbug
13:07:12.542 Add 2 4 local. _rfb._tcp. Tesla

$ ps aux |grep dns-sd
# no matching processes found
```

There's still one more problem to solve. If there's no VNC service available `dns-sd` won't return a line for us to check the Flags column for value != 3, therefore the loop will never break and the script will run forever. 

## Still trapped in the loop

The nature of `dns-sd` prevents us from breaking the loop in this case but if there are results they are returned almost instantly (they're probably kept in memory). Due to this fact we can assume that after a couple of hundred milliseconds there won't be any results any time soon and we can kill the script after a short period. To achieve this we use `sleep` as a timer followed by a `kill`.

```
#!/bin/bash
i=0
while read -r line; do
    i=`expr $i + 1`
    if [ $i -lt 5 ]; then continue; fi # skip the header lines
    
	echo $line
	
	# break if no more items will follow (e.g. Flags != 3)
	if [ $(echo $line | cut -d ' ' -f 3) -ne '3' ]; then
		break
	fi
done < <((sleep 0.5; kill -13 0) & # kill quickly if trapped
			dns-sd -B _rfb._tcp)

# kill child processes
kill -13 0
```

A new child process (`(sleep 0.5; kill -13 0) &`) is now running in the background followed by the `dns-sd` process. After 500ms it sends a SIGPIPE and the script will exit, no matter what. It's important to remember that any code after the loop is not executed in this case, as the script is terminated while still being trapped in the loop.

## Do some work before termination

For being able to run code before exiting the script we can define a `trap`. This is helpful if we want to run some more logic on the results which might take longer than 500ms and would be brutally killed by our timer.

```
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
```

At this point we're done. To run the above script paste the following line into your terminal:

```
bash <(curl -s https://raw.github.com/pstadler/non-terminating-bash-processes/master/discover-vnc.sh)
```

This approach is being used in the following projects:

- [Screen Sharing for Alfred](https://github.com/pstadler/alfred-screensharing) — Connect to a host in Alfred with automatic network discovery.
- [Mount Network Shares with Alfred](https://github.com/pstadler/alfred-mount) — Use Alfred to connect to your network shares with ease.

## Conclusion

Advanced Bash scripting can cause nasty hacks and unexpected side-effects but there's always a way to work around them. Many ways lead to rome and there could be a more sane way to achieve the same.

Please get in touch with me if you have any questions or suggestions related to this topic. You can find me on [Twitter](https://twitter.com/pstadler) and [GitHub](https://github.com/pstadler).
