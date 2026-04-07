#!/bin/bash

# ===== User settings =====
# Usage:
#   ./monitor_interfoam.sh
#   ./monitor_interfoam.sh interFoam1.log

LOGFILE="${1:-interFoam1.log}"

if [ ! -f "$LOGFILE" ]; then
    echo "Error: log file '$LOGFILE' not found."
    exit 1
fi

# ===== Auto-detect OUTER_ITERS and N_CORRECTORS =====

OUTER_ITERS=$(awk '
/^PIMPLE: Iteration/ {
    if ($3+0 > maxIter) maxIter = $3
}
END { print (maxIter > 0 ? maxIter : 1) }
' "$LOGFILE")

N_CORRECTORS=$(awk '
/^Time =/ {
    if (count > maxCount) maxCount = count
    count = 0
}
/Solving for p_rgh,/ {
    count++
}
END {
    if (count > maxCount) maxCount = count
    # divide by OUTER_ITERS later in bash
    print maxCount
}
' "$LOGFILE")

# Divide total p_rgh solves by OUTER_ITERS to get correctors
if [ "$OUTER_ITERS" -gt 0 ]; then
    N_CORRECTORS=$((N_CORRECTORS / OUTER_ITERS))
fi

# Safety fallback
if [ "$N_CORRECTORS" -lt 1 ]; then
    N_CORRECTORS=1
fi

echo "Detected OUTER_ITERS=$OUTER_ITERS"
echo "Detected N_CORRECTORS=$N_CORRECTORS"

# ===== Output directory =====
OUTDIR="monitor"

if [ ! -d "$OUTDIR" ]; then
    mkdir "$OUTDIR"
fi

rm -f "$OUTDIR"/*.dat "$OUTDIR"/*.png

# ===== Parse log =====
awk -v outdir="$OUTDIR" -v outerIters="$OUTER_ITERS" -v nCorr="$N_CORRECTORS" '

function key2(a,b)    { return a "-" b }
function key3(a,b,c)  { return a "-" b "-" c }

function getOrNaN(arr, k) {
    if (k in arr) return arr[k]
    else return "NaN"
}

BEGIN {
    stepIdx = 0
    iter = 0
    pCorrCount = 0
    CoMean = ""
    CoMax = ""
    ICoMean = ""
    ICoMax = ""
    deltaTVal = ""
}

# ---- Courant number ----
/^Courant Number mean:/ {
    CoMean = $4
    CoMax  = $6
}

# ---- Interface Courant number ----
/^Interface Courant Number mean:/ {
    ICoMean = $5
    ICoMax  = $7
}

# ---- deltaT ----
/^deltaT =/ {
    deltaTVal = $3
}

# ---- New time step ----
/^Time =/ {
    timeVal = $3
    stepIdx++
    iter = 0
    pCorrCount = 0
}

# ---- Outer PIMPLE iteration ----
/^PIMPLE: Iteration/ {
    iter = $3
    pCorrCount = 0
}

# ---- Pressure residuals: p_rgh ----
/Solving for p_rgh,/ {
    res = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "Final" && $(i+1) == "residual") {
            res = $(i+3)
            break
        }
    }

    if (res != "" && iter > 0) {
        pCorrCount++
        # store by (step, outer iteration, pressure corrector index)
        PRghRes[key3(stepIdx, iter, pCorrCount)] = res

        # also keep the latest one seen in this outer iteration
        PRghLastRes[key2(stepIdx, iter)] = res
    }
}

# ---- Outlet flux (rhoPhi) ----
/sum\(outlet\) of rhoPhi =/ {
    flux = $NF
}

# ---- Turbulence residuals ----
/smoothSolver:  Solving for k,/ {
    res = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "Final" && $(i+1) == "residual") {
            res = $(i+3)
            break
        }
    }
    if (res != "" && stepIdx > 0) {
        KRes[stepIdx] = res
    }
}

/smoothSolver:  Solving for epsilon,/ {
    res = ""
    for (i = 1; i <= NF; i++) {
        if ($i == "Final" && $(i+1) == "residual") {
            res = $(i+3)
            break
        }
    }
    if (res != "" && stepIdx > 0) {
        EpsRes[stepIdx] = res
    }
}

# ---- Execution time: write one record per time-step ----
/^ExecutionTime =/ {
    execT = $3
    currentTime = timeVal

    # p_rgh residual for last outer iteration and requested corrector
    wantedKey = key3(stepIdx, outerIters, nCorr)
    fallbackKey = key2(stepIdx, outerIters)

    pFinal = ""
    if (wantedKey in PRghRes) {
        pFinal = PRghRes[wantedKey]
    } else if (fallbackKey in PRghLastRes) {
        # fallback if actual number of p correctors differs
        pFinal = PRghLastRes[fallbackKey]
    }

    kFinal   = (stepIdx in KRes   ? KRes[stepIdx]   : "NaN")
    epsFinal = (stepIdx in EpsRes ? EpsRes[stepIdx] : "NaN")

    # cumulative execution time
    if (currentTime != "") {
        print currentTime, execT >> outdir"/timing_cum.dat"
    }

    # residuals vs time
    if (currentTime != "") {
        print currentTime, pFinal, kFinal, epsFinal >> outdir"/residuals.dat"
    }

    # Discharge (convert from rhoPhi to m3/s)
    if (currentTime != "" && flux != "") {
        Q = flux / 1000.0
        print currentTime, Q >> outdir"/discharge.dat"
    }

    # CPU seconds per simulated second
    if (prevTime != "" && prevExec != "") {
        dTime = currentTime - prevTime
        dExec = execT - prevExec
        if (dTime > 0) {
            cpu = dExec / dTime
            if (cpu < 0) cpu = 0
            print currentTime, cpu >> outdir"/timing_step.dat"
        }
    }

    # Courant and deltaT
    if (currentTime != "" && CoMean != "" && CoMax != "" && ICoMean != "" && ICoMax != "") {
        dtOut = (deltaTVal != "" ? deltaTVal : "NaN")
        print currentTime, CoMean, CoMax, ICoMean, ICoMax, dtOut >> outdir"/courant.dat"
    }

    prevTime = currentTime
    prevExec = execT
}

END {
    if (stepIdx == 0) exit

    # last 10 time-steps: p_rgh residual by outer iteration
    startStep = stepIdx - 9
    if (startStep < 1) startStep = 1

    globalIdx = 0
    for (s = startStep; s <= stepIdx; s++) {
        for (it = 1; it <= outerIters; it++) {
            globalIdx++
            wantedKey = key3(s, it, nCorr)
            fallbackKey = key2(s, it)

            pVal = "NaN"
            if (wantedKey in PRghRes) {
                pVal = PRghRes[wantedKey]
            } else if (fallbackKey in PRghLastRes) {
                pVal = PRghLastRes[fallbackKey]
            }

            print globalIdx, pVal >> outdir"/residuals_iters.dat"
        }
    }
}
' "$LOGFILE"

# ===== Plot =====
gnuplot << EOF

set term pngcairo size 1000,700

# Plot 1: residuals vs time
set output "$OUTDIR/residuals.png"
set logscale y
set xlabel "Simulation time [s]"
set ylabel "Final residual"
set grid
plot \
    "$OUTDIR/residuals.dat" using 1:2 with linespoints title "p_rgh final residual", \
    "$OUTDIR/residuals.dat" using 1:3 with linespoints title "k final residual", \
    "$OUTDIR/residuals.dat" using 1:4 with linespoints title "epsilon final residual"

# Plot 2: CPU time per simulated second
set output "$OUTDIR/cpu_per_sim_second.png"
unset logscale y
set xlabel "Simulation time [s]"
set ylabel "CPU seconds per simulated second"
set yrange [0:*]
set grid
plot \
    "$OUTDIR/timing_step.dat" using 1:2 with linespoints title "CPU time per simulated second"
unset yrange

# Plot 3: cumulative execution time
set output "$OUTDIR/execution_time.png"
set xlabel "Simulation time [s]"
set ylabel "Cumulative ExecutionTime [s]"
set grid
plot \
    "$OUTDIR/timing_cum.dat" using 1:2 with linespoints title "ExecutionTime"

# Plot 4: last 10 time-steps, p_rgh residual across outer iterations
set output "$OUTDIR/residuals_last10.png"
set logscale y
set xlabel "Global PIMPLE iteration index"
set ylabel "p_rgh final residual"
set grid
plot \
    "$OUTDIR/residuals_iters.dat" using 1:2 with linespoints title "p_rgh"
unset logscale y

# Plot 5: Courant and deltaT
set output "$OUTDIR/courant.png"
set xlabel "Simulation time [s]"
set ylabel "Courant number"
set y2label "deltaT [s]"
set ytics nomirror
set y2tics
set grid
plot \
    "$OUTDIR/courant.dat" using 1:2 with linespoints title "Co mean" axes x1y1, \
    "$OUTDIR/courant.dat" using 1:3 with linespoints title "Co max" axes x1y1, \
    "$OUTDIR/courant.dat" using 1:4 with linespoints title "Interface Co mean" axes x1y1, \
    "$OUTDIR/courant.dat" using 1:5 with linespoints title "Interface Co max" axes x1y1, \
    "$OUTDIR/courant.dat" using 1:6 with linespoints title "deltaT" axes x1y2

# Plot 6: discharge
set output "$OUTDIR/discharge.png"
set xlabel "Simulation time [s]"
set ylabel "Discharge Q [m^3/s]"
set grid
plot \
    "$OUTDIR/discharge.dat" using 1:2 with linespoints title "Outlet discharge"

unset output
EOF

echo "Done."
echo "All data and plots are inside: $OUTDIR/"
echo "Configured OUTER_ITERS=$OUTER_ITERS , N_CORRECTORS=$N_CORRECTORS"