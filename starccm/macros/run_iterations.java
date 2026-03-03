// run_iterations.java — Reset iteration count and run N more iterations
// Usage: starccm+ -power -np 176 -batch run_iterations.java model.sim
//
// The number of iterations is read from a file called "iterations.txt"
// in the current working directory. If not found, defaults to 100.

import star.common.*;
import star.base.neo.*;
import java.io.*;

public class run_iterations extends StarMacro {
    public void execute() {
        Simulation sim = getActiveSimulation();

        // Number of additional iterations to run (default: 100)
        int numIterations = 100;
        try {
            BufferedReader br = new BufferedReader(new FileReader("iterations.txt"));
            String line = br.readLine().trim();
            br.close();
            numIterations = Integer.parseInt(line);
        } catch (Exception e) {
            sim.println("No iterations.txt found or invalid, using default: " + numIterations);
        }

        // Get current iteration count
        int currentStep = sim.getSimulationIterator().getCurrentIteration();

        sim.println("=== run_iterations macro ===");
        sim.println("Current iteration : " + currentStep);
        sim.println("Running iters     : " + numIterations);

        // Disable auto-save to avoid permission errors on read-only model locations
        AutoSave autoSave = sim.getSimulationIterator().getAutoSave();
        autoSave.setAutoSaveBatch(false);

        // Step exactly N iterations (ignores model stopping criteria)
        sim.getSimulationIterator().step(numIterations);

        int finalIter = sim.getSimulationIterator().getCurrentIteration();
        sim.println("=== Simulation complete at iteration " + finalIter + " ===");
    }
}
