#!/bin/bash

# ===== User settings =====
# Usage:
#   ./monitor.sh           # uses default pimple2.log
#   ./monitor.sh other.log # uses other.log instead
LOGFILE="${1:-pimple2.log}"

if [ ! -f "$LOGFILE" ]; then
    echo "Error: log file '$LOGFILE' not found."
    exit 1
fi

# ===== Create monitor directory =====
OUTDIR="monitor"

if [ ! -d "$OUTDIR" ]; then
    mkdir "$OUTDIR"
fi

# Clean old data files inside monitor/
rm -f "$OUTDIR"/*.dat "$OUTDIR"/*.png

# ===== AWK parsing of OpenFOAM log =====
awk -v outdir="$OUTDIR" '

function key(s, it) { return s "-" it }

function getOrNaN(arr, k) {
    if (k in arr) return arr[k]
    else return "NaN"
}

# ---- Courant number ----
/^Courant Number mean:/ {
    # Example:
    # Courant Number mean: 0.00867386 max: 0.412145
    CoMean = $4
    CoMax  = $6
}

# ---- deltaT ----
/^deltaT =/ {
    # Example:
    # deltaT = 0.00239923
    deltaTVal = $3
}

/^Time =/ {
    timeVal = $3
    iter = 0
    stepIdx++
}

/^PIMPLE: Iteration/ {
    iter = $3
}

/smoothSolver:  Solving for Ux,/ {
    res = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "Final" && $(i+1) == "residual") {
            res = $(i+3)
            break
        }
    }
    if (res != "" && iter > 0)
        UxRes[key(stepIdx, iter)] = res
}

/smoothSolver:  Solving for Uz,/ {
    res = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "Final" && $(i+1) == "residual") {
            res = $(i+3)
            break
        }
    }
    if (res != "" && iter > 0)
        UzRes[key(stepIdx, iter)] = res
}

/GAMG:  Solving for p,/ {
    res = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "Final" && $(i+1) == "residual") {
            res = $(i+3)
            break
        }
    }
    if (res != "" && iter > 0)
        PRes[key(stepIdx, iter)] = res
}

/forceCoeffs forceCoeffs write:/ {
    inForces = 1
    CmVal = ""; CdVal = ""; ClVal = ""
}

inForces && $1 == "Cm" { CmVal = $3 }
inForces && $1 == "Cd" { CdVal = $3 }
inForces && $1 == "Cl" { ClVal = $3 }

inForces {
    if (CmVal != "" && CdVal != "" && ClVal != "" && timeVal != "") {
        print timeVal, CdVal, CmVal, ClVal >> outdir"/forces.dat"
        inForces = 0
    }
}

/^ExecutionTime =/ {
    execT = $3
    currentTime = timeVal

    k3 = key(stepIdx, 3)

    Ufinal = ""
    if (k3 in UxRes) Ufinal = UxRes[k3]
    if (k3 in UzRes && (Ufinal == "" || UzRes[k3] > Ufinal))
        Ufinal = UzRes[k3]

    Pfinal = ""
    if (k3 in PRes) Pfinal = PRes[k3]

    if (currentTime != "")
        print currentTime, execT >> outdir"/timing_cum.dat"

    if (currentTime != "" && Ufinal != "" && Pfinal != "")
        print currentTime, Ufinal, Pfinal >> outdir"/residuals.dat"

    if (prevTime != "" && prevExec != "") {
        dTime = currentTime - prevTime
        dExec = execT - prevExec
        if (dTime > 0)
            print currentTime, dExec/dTime >> outdir"/timing_step.dat"
    }

    # Courant number and deltaT vs time
    if (currentTime != "" && CoMean != "" && CoMax != "") {
        dtOut = (deltaTVal != "" ? deltaTVal : "NaN")
        print currentTime, CoMean, CoMax, dtOut >> outdir"/courant.dat"
    }

    prevTime = currentTime
    prevExec = execT
}

END {
    if (stepIdx == 0) exit

    startStep = stepIdx - 9
    if (startStep < 1) startStep = 1

    globalIdx = 0
    for (s = startStep; s <= stepIdx; s++) {
        for (it = 1; it <= 3; it++) {
            globalIdx++
            k = key(s, it)
            ux = getOrNaN(UxRes, k)
            uz = getOrNaN(UzRes, k)
            pp = getOrNaN(PRes,  k)
            print globalIdx, ux, uz, pp >> outdir"/residuals_iters.dat"
        }
    }
}
' "$LOGFILE"

# ===== Gnuplot section =====
gnuplot << EOF

set term pngcairo size 1000,700

# Plot 1
set output "$OUTDIR/residuals.png"
set logscale y
set xlabel "Simulation time [s]"
set ylabel "Final residual (PIMPLE iteration 3)"
set grid
plot \
    "$OUTDIR/residuals.dat" using 1:2 with linespoints title "U final residual (iter 3)", \
    "$OUTDIR/residuals.dat" using 1:3 with linespoints title "p final residual (iter 3)"

# Plot 2
set output "$OUTDIR/cpu_per_sim_second.png"
unset logscale y
set xlabel "Simulation time [s]"
set ylabel "CPU seconds per simulated second"
set yrange [0:*]
set grid
plot "$OUTDIR/timing_step.dat" using 1:2 with linespoints title "CPU time per simulated second"
unset yrange

# Plot 3
set output "$OUTDIR/execution_time.png"
set xlabel "Simulation time [s]"
set ylabel "Cumulative ExecutionTime [s]"
set grid
plot "$OUTDIR/timing_cum.dat" using 1:2 with linespoints title "ExecutionTime"

# Plot 4
set output "$OUTDIR/residuals_last10.png"
set logscale y
set xlabel "Global PIMPLE iteration index"
set ylabel "Final residual"
set grid
plot \
    "$OUTDIR/residuals_iters.dat" using 1:2 with linespoints title "Ux", \
    "$OUTDIR/residuals_iters.dat" using 1:3 with linespoints title "Uz", \
    "$OUTDIR/residuals_iters.dat" using 1:4 with linespoints title "p"

# Plot 5
set output "$OUTDIR/forceCoeffs.png"
unset logscale y
set xlabel "Simulation time [s]"
set ylabel "Force coefficients"
set yrange [-2:2]
set grid
plot \
    "$OUTDIR/forces.dat" using 1:2 with linespoints title "Cd", \
    "$OUTDIR/forces.dat" using 1:3 with linespoints title "Cm", \
    "$OUTDIR/forces.dat" using 1:4 with linespoints title "Cl"

# Plot 6
set output "$OUTDIR/courant.png"
set xlabel "Simulation time [s]"
set ylabel "Courant number"
set yrange [0:*]
set y2label "deltaT [s]"
set ytics nomirror
set y2tics
set grid
unset logscale y
unset logscale y2
plot \
    "$OUTDIR/courant.dat" using 1:2 with linespoints title "Co mean" axes x1y1, \
    "$OUTDIR/courant.dat" using 1:3 with linespoints title "Co max"  axes x1y1, \
    "$OUTDIR/courant.dat" using 1:4 with linespoints title "deltaT"  axes x1y2
unset yrange

unset output
EOF

echo "Done."
echo "All data and plots are inside: $OUTDIR/"