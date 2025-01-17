push!(Base.LOAD_PATH, "../../")

using AtomsBase
using InteratomicPotentials
using PotentialLearning
using Unitful, UnitfulAtomic
using LinearAlgebra
using CairoMakie
#using JLD

# Load dataset
confs, thermo = load_data("data/liquify_sodium.yaml", YAML(:Na, u"eV", u"Å"))
confs, thermo = confs[220:end], thermo[220:end]

# Split dataset
conf_train, conf_test = confs[1:1000], confs[1001:end]

# Define ACE
ace = ACE(species = [:Na],         # species
          body_order = 4,          # 4-body
          polynomial_degree = 8,   # 8 degree polynomials
          wL = 1.0,                # Defaults, See ACE.jl documentation 
          csp = 1.0,               # Defaults, See ACE.jl documentation 
          r0 = 1.0,                # minimum distance between atoms
          rcutoff = 5.0)           # cutoff radius 

# Update training dataset by adding energy (local) descriptors
println("Computing local descriptors of training dataset")
e_descr_train = compute_local_descriptors(conf_train, ace)
#e_descr_train = JLD.load("data/sodium_empirical_full.jld", "descriptors")
ds_train = DataSet(conf_train .+ e_descr_train)

# Learn using DPP
lb = LBasisPotential(ace)
dpp = kDPP(ds_train, GlobalMean(), DotProduct(); batch_size = 200)
dpp_inds = get_random_subset(dpp)
α = 1e-8
Σ = learn!(lb, ds_train[dpp_inds], α)

# Post-process output

# Update test dataset by adding energy and force descriptors
println("Computing local descriptors of test dataset")
e_descr_test = compute_local_descriptors(conf_test, ace)
ds_test = DataSet(conf_test .+ e_descr_test)

# Get true and predicted energy values (assuming that all configurations have the same no. of atoms)
n = size(get_system(ds_train[1]))[1]
e_train, e_train_pred = get_all_energies(ds_train)/n, get_all_energies(ds_train, lb)/n
e_test, e_test_pred   = get_all_energies(ds_test)/n, get_all_energies(ds_test, lb)/n

# Compute and print metrics
e_mae, e_rmse, e_rsq = calc_metrics(e_train, e_train_pred)
println("MAE: $e_mae, RMSE: $e_rmse, RSQ: $e_rsq")

# Plot energy error scatter
e_err_train, e_err_test = (e_train_pred - e_train), (e_test_pred - e_test)
dpp_inds2 = get_random_subset(dpp; batch_size = 20)
size_inches = (12, 8)
size_pt = 72 .* size_inches
fig = Figure(resolution = size_pt, fontsize = 16)
ax1 = Axis(fig[1, 1], xlabel = "Energy (eV/atom)", ylabel = "Error (eV/atom)")
scatter!(ax1, e_train, e_err_train, label = "Training", markersize = 5.0)
scatter!(ax1, e_test, e_err_test, label = "Test", markersize = 5.0)
scatter!(ax1, e_train[dpp_inds2], e_err_train[dpp_inds2], markersize = 5.0,
         color = :darkred, label = "DPP Samples")
axislegend(ax1)
save("figures/energy_error_training_test_scatter.pdf", fig)
display(fig)


