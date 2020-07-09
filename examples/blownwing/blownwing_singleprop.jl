#=##############################################################################
# DESCRIPTION
Test rotor model simulating an isolated 10in propeller in forward flight. The
rotor and configuration approximates the APC Thin Electric 10x7 propeller as
used in McCrink, M. H., & Gregory, J. W. (2017), *Blade Element Momentum
Modeling of Low-Reynolds Electric Propulsion Systems*.

# AUTHORSHIP
  * Author    : Eduardo J. Alvarez
  * Email     : Edo.AlvarezR@gmail.com
  * Created   : Dec 2019
  * License   : MIT
=###############################################################################

# ------------------------------------------------------------------------------

function singleprop(; xfoil=true,
                        # OUTPUT OPTIONS
                        save_path=nothing,
                        run_name="singlerotor",
                        prompt=true,
                        verbose=true, v_lvl=0)

    # TODO: Wake removal ?

    # ------------ PARAMETERS --------------------------------------------------

    # Rotor geometry
    rotor_file = "apc10x7.csv"          # Rotor geometry
    data_path = uns.def_data_path       # Path to rotor database
    pitch = 0.0                         # (deg) collective pitch of blades
    n = 10                              # Number of blade elements
    CW = false                          # Clock-wise rotation
    # xfoil = false                     # Whether to run XFOIL

    # Read radius of this rotor and number of blades
    R, B = uns.read_rotor(rotor_file; data_path=data_path)[[1,3]]

    # Simulation parameters
    J = 0.6                             # Advance ratio Vinf/(nD)
    ReD07 = 1.5e6                       # Diameter-based Reynolds at 70% span
    ReD = ReD07/0.7                     # Diameter-based Reynolds
    rho = 1.225                         # (kg/m^3) air density
    mu = 1.81e-5                        # (kg/ms) air dynamic viscosity
    nu = mu/rho
    sound_spd = 343                     # (m/s) speed of sound
    RPM = uns.calc_RPM(ReD, J, R, 2*R, nu) # RPM
    magVinf = J*RPM/60*2*R              # (m/s) freestream velocity
    Minf = magVinf / sound_spd
    Mtip = 2*pi*RPM/60*R / sound_spd

    if verbose
        println("\t"^(v_lvl+1)*"OPERATION PARAMETERS")
        println("\t"^(v_lvl+2)*"J:\t\t$(J)")
        println("\t"^(v_lvl+2)*"ReD07:\t\t$(ReD07)")
        println("\t"^(v_lvl+2)*"RPM:\t\t$(ceil(Int, RPM))")
        println("\t"^(v_lvl+2)*"Mtip:\t\t$(round(Mtip, digits=3))")
        println("\t"^(v_lvl+2)*"Minf:\t\t$(round(Minf, digits=3))")
    end

    Vinf(X,t) = magVinf*[1.0,0,0]       # (m/s) freestream velocity

    # Solver parameters
    nrevs = 8                           # Number of revolutions in simulation
    # nsteps_per_rev = 72               # Time steps per revolution
    nsteps_per_rev = 36
    # p_per_step = 2                    # Sheds per time step
    p_per_step = 1
    ttot = nrevs/(RPM/60)               # (s) total simulation time
    nsteps = nrevs*nsteps_per_rev       # Number of time steps
    lambda = 2.125                      # Core overlap
    overwrite_sigma = lambda * 2*pi*R/(nsteps_per_rev*p_per_step) # Smoothing core size
    surf_sigma = R/10                   # Smoothing radius of lifting surface
    # vlm_sigma = surf_sigma            # Smoothing radius of VLM
    vlm_sigma = -1
    shed_unsteady = true                # Shed particles from unsteady loading

    max_particles = ((2*n+1)*B)*nrevs*nsteps_per_rev*p_per_step # Max particles for memory pre-allocation
    plot_disc = true                    # Plot blade discretization for debugging


    # ------------ SIMULATION SETUP --------------------------------------------
    # Generate rotor
    rotor = uns.generate_rotor(rotor_file; pitch=pitch,
                                            n=n, CW=CW, ReD=ReD,
                                            verbose=verbose, xfoil=xfoil,
                                            data_path=data_path,
                                            plot_disc=plot_disc)
    # ----- VEHICLE DEFINITION
    # System of all FLOWVLM objects
    system = vlm.WingSystem()
    vlm.addwing(system, run_name, rotor)

    # Systems of rotors
    rotors = vlm.Rotor[rotor]   # Defining this rotor as its own system
    rotor_systems = (rotors,)

    # Wake-shedding system
    wake_system = vlm.WingSystem()
    vlm.addwing(wake_system, run_name, rotor)

    # FVS's Vehicle object
    vehicle = uns.VLMVehicle(   system;
                                rotor_systems=rotor_systems,
                                wake_system=wake_system
                             )

    # ----- MANEUVER DEFINITION
    RPM_fun(t) = 1.0                # RPM (normalized by reference RPM) as a
                                    # function of normalized time

    angle = ()                      # Angle of each tilting system (none in this case)
    sysRPM = (RPM_fun, )              # RPM of each rotor system
    Vvehicle(t) = zeros(3)          # Translational velocity of vehicle over Vcruise
    anglevehicle(t) = zeros(3)      # (deg) angle of the vehicle

    # FVS's Maneuver object
    maneuver = uns.KinematicManeuver(angle, sysRPM, Vvehicle, anglevehicle)

    # Plot maneuver path and controls
    uns.plot_maneuver(maneuver; vis_nsteps=nsteps)


    # ----- SIMULATION DEFINITION
    RPMref = RPM
    Vref = 0.0
    simulation = uns.Simulation(vehicle, maneuver, Vref, RPMref, ttot)

    monitor = generate_monitor_prop(J, rho, RPM, nsteps; save_path=save_path,
                                                            run_name=run_name)


    # ------------ RUN SIMULATION ----------------------------------------------
    pfield = uns.run_simulation(simulation, nsteps;
                                      # SIMULATION OPTIONS
                                      Vinf=Vinf,
                                      # SOLVERS OPTIONS
                                      p_per_step=p_per_step,
                                      overwrite_sigma=overwrite_sigma,
                                      vlm_sigma=vlm_sigma,
                                      surf_sigma=surf_sigma,
                                      max_particles=max_particles,
                                      shed_unsteady=shed_unsteady,
                                      extra_runtime_function=monitor,
                                      # OUTPUT OPTIONS
                                      save_path=save_path,
                                      run_name=run_name,
                                      prompt=prompt,
                                      verbose=verbose, v_lvl=v_lvl,
                                      save_code=splitdir(@__FILE__)[1],
                                      )
    return pfield, rotor
end


"""
Generate monitor for rotor performance parameters
"""
function generate_monitor_prop(J, rho, RPM, nsteps; save_path=nothing,
                                run_name="singlerotor",
                                figname="monitor_rotor", disp_conv=true,
                                nsteps_savefig=10)

    fcalls = 0                  # Number of function calls

    colors="rgbcmy"^100
    stls = "o^*.px"^100

    # Name of convergence file
    if save_path!=nothing
        fname = joinpath(save_path, run_name*"_convergence.csv")
    end

    # Function for run_vpm! to call on each iteration
    function extra_runtime_function(sim::uns.Simulation{V, M, R},
                                    PFIELD::uns.vpm.ParticleField,
                                    T::Real, DT::Real
                                   ) where{V<:uns.AbstractVLMVehicle, M, R}

        rotors = vcat(sim.vehicle.rotor_systems...)
        angle = T*360*RPM/60


        # Call figure
        if disp_conv; fig = figure(figname, figsize=(7*3,5*2)); end;

        if fcalls==0
            # Format subplots
            if disp_conv
                subplot(231)
                title("Circulation Distribution")
                xlabel("Element index")
                ylabel(L"Circulation $\Gamma$ (m$^2$/s)")
                grid(true, color="0.8", linestyle="--")
                subplot(232)
                title("Plane-of-rotation Normal Force")
                xlabel("Element index")
                ylabel(L"Normal Force $N_p$ (N)")
                grid(true, color="0.8", linestyle="--")
                subplot(233)
                title("Plane-of-rotation Tangential Force")
                xlabel("Element index")
                ylabel(L"Tangential Force $T_p$ (N)")
                grid(true, color="0.8", linestyle="--")
                subplot(234)
                xlabel(L"Age $\psi$ ($^\circ$)")
                ylabel(L"Thrust $C_T$")
                grid(true, color="0.8", linestyle="--")
                subplot(235)
                xlabel(L"Age $\psi$ ($^\circ$)")
                ylabel(L"Torque $C_Q$")
                grid(true, color="0.8", linestyle="--")
                subplot(236)
                xlabel(L"Age $\psi$ ($^\circ$)")
                ylabel(L"Propulsive efficiency $\eta$")
                grid(true, color="0.8", linestyle="--")
            end

            # Convergence file header
            if save_path!=nothing
                f = open(fname, "w")
                print(f, "age (deg),T,DT")
                for (i, rotor) in enumerate(rotors)
                    print(f, ",RPM_$i,CT_$i,CQ_$i,eta_$i")
                end
                print(f, "\n")
                close(f)
            end
        end

        # Write rotor position and time on convergence file
        if save_path!=nothing
            f = open(fname, "a")
            print(f, angle, ",", T, ",", DT)
        end


        # Plot circulation and loads distributions
        if disp_conv

            cratio = PFIELD.nt/nsteps
            cratio = cratio > 1 ? 1 : cratio
            clr = fcalls==0 && false ? (0,0,0) : (1-cratio, 0, cratio)
            stl = fcalls==0 && false ? "o" : "-"
            alpha = fcalls==0 && false ? 1 : 0.5

            # Circulation distribution
            subplot(231)
            this_sol = []
            for rotor in rotors
                this_sol = vcat(this_sol, [vlm.get_blade(rotor, j).sol["Gamma"] for j in 1:rotor.B]...)
            end
            plot(1:size(this_sol,1), this_sol, stl, alpha=alpha, color=clr)

            # Np distribution
            subplot(232)
            this_sol = []
            for rotor in rotors
                this_sol = vcat(this_sol, rotor.sol["Np"]["field_data"]...)
            end
            plot(1:size(this_sol,1), this_sol, stl, alpha=alpha, color=clr)

            # Tp distribution
            subplot(233)
            this_sol = []
            for rotor in rotors
                this_sol = vcat(this_sol, rotor.sol["Tp"]["field_data"]...)
            end
            plot(1:size(this_sol,1), this_sol, stl, alpha=alpha, color=clr)
        end

        # Plot performance parameters
        for (i,rotor) in enumerate(rotors)
            CT, CQ = vlm.calc_thrust_torque_coeffs(rotor, rho)
            eta = J*CT/(2*pi*CQ)

            if disp_conv
                subplot(234)
                plot([angle], [CT], "$(stls[i])", alpha=alpha, color=clr)
                subplot(235)
                plot([angle], [CQ], "$(stls[i])", alpha=alpha, color=clr)
                subplot(236)
                plot([angle], [eta], "$(stls[i])", alpha=alpha, color=clr)
            end

            if save_path!=nothing
                print(f, ",", rotor.RPM, ",", CT, ",", CQ, ",", eta)
            end
        end

        if disp_conv
            # Save figure
            if fcalls%nsteps_savefig==0 && fcalls!=0 && save_path!=nothing
                savefig(joinpath(save_path, run_name*"_convergence.png"),
                                                            transparent=false)
            end
        end

        # Close convergence file
        if save_path!=nothing
            print(f, "\n")
            close(f)
        end

        fcalls += 1

        return false
    end

    return extra_runtime_function
end