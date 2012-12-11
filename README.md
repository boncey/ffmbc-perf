ffmbc-perf
==========

A simple performance test suite for FFmbc (and/or any process in fact).  
*Note:* Probably highly idiosyncratic. :-)


Originally developed to test [FFmbc](http://code.google.com/p/ffmbc/) transcode speeds but could probably be used to measure any command line process - should work fine with FFmpeg too.

Set up your command lines in yaml and results are output to stdout in CSV format.

Requirements
----------

* Standard Ruby installation
* [FFmbc](http://code.google.com/p/ffmbc/)
* [Mediainfo](http://mediainfo.sourceforge.net/en)
* Some video files

How to use
----------

Hack on the example yaml file.

* name (this will be output as the test name in the CSV output)
* command (full FFmbc command; INTERLACED_OPTION and SCALING_OPTION will be substituted if provided and mediainfo detects they are required)
* interlaced_option (see below)
* scaling_option (see below)
* ext (the output file extension)
* processes (see below)

Interlaced and Scaling options
-----

Mediainfo is run on each file to determine the frame size and if the source is interlaced.

If the interlaced_option and/or scaling_option values are provided *AND* INTERLACED_OPTION and SCALING_OPTION are aded to the command line then these values will be substituted if Mediainfo detects that they are required.

If the source is not interlaced then the interlaced option won't be added.
If the frame width is not 1440 then the scaling option won't be added.

Parallelisation
-----

The processes field is used to run processes in parallel.
It's set as a YAML array of number of parallel processes to run as.

Each combination is run in turn.

Eg, [1, 2, 4] will run your command once, then run two instances in parallel, then finally four instances in parallel.
Each run records its own timings.
