using AtomsBase
using Unitful, UnitfulAtomic
using InteratomicPotentials 
using InteratomicBasisPotentials
using PotentialLearning
using LinearAlgebra
using Random
include("utils/utils.jl")


# Load input parameters
args = ["experiment_path",      "a-Hfo2-300K-NVT-6000/", 
        "dataset_path",         "data/",
        "dataset_filename",     "a-Hfo2-300K-NVT-6000.extxyz",
        "random_seed",          "100",
        "n_train_sys",          "800",
        "n_test_sys",           "200",
        "n_body",               "3",
        "max_deg",              "3",
        "r0",                   "1.0",
        "rcutoff",              "5.0",
        "wL",                   "1.0",
        "csp",                  "1.0",
        "w_e",                  "1.0",
        "w_f",                  "1.0"]
args = length(ARGS) > 0 ? ARGS : args
input = get_input(args)


# Create experiment folder
path = input["experiment_path"]
run(`mkdir -p $path`)
@savecsv path input

# Fix random seed
if "random_seed" in keys(input)
    Random.seed!(input["random_seed"])
end

# Load dataset
ds_path = input["dataset_path"]*input["dataset_filename"] # dirname(@__DIR__)*"/data/"*input["dataset_filename"]
ds = load_data(ds_path, ExtXYZ(u"eV", u"Å"))

# Split dataset
n_train, n_test = input["n_train_sys"], input["n_test_sys"]
conf_train, conf_test = split(ds, n_train, n_test)

# Start measuring learning time
learn_time = @elapsed begin

# Define ACE parameters
ace_basis = ACE(species = unique(atomic_symbol(get_system(ds[1]))),
                body_order = input["n_body"],
                polynomial_degree = input["max_deg"],
                wL = input["wL"],
                csp = input["csp"],
                r0 = input["r0"],
                rcutoff = input["rcutoff"])
@savevar path ace_basis

# Update training dataset by adding energy and force descriptors
println("Computing energy descriptors of training dataset...")
B_time = @elapsed e_descr_train = compute_local_descriptors(conf_train, ace_basis)
println("Computing force descriptors of training dataset...")
dB_time = @elapsed f_descr_train = compute_force_descriptors(conf_train, ace_basis)
GC.gc()
ds_train = DataSet(conf_train .+ e_descr_train .+ f_descr_train)

# Learn
println("Learning energies and forces...")
lp = PotentialLearning.LinearProblem(ds_train)
w_e = input["w_e"]; w_f = input["w_f"]
learn!(lp, w_e, w_f)

end # end of "learn_time = @elapsed begin"

@savevar path lp.β

# Post-process output: calculate metrics, create plots, and save results

# Update test dataset by adding energy and force descriptors
println("Computing energy descriptors of test dataset...")
e_descr_test = compute_local_descriptors(conf_test, ace_basis)
println("Computing force descriptors of test dataset...")
f_descr_test = compute_force_descriptors(conf_test, ace_basis)
GC.gc()
ds_test = DataSet(conf_test .+ e_descr_test .+ f_descr_test)


# Get true and predicted values
e_train, f_train = get_all_energies(ds_train), get_all_forces(ds_train)
e_test, f_test = get_all_energies(ds_test), get_all_forces(ds_test)
e_train_pred, f_train_pred = get_all_energies(ds_train, lp), get_all_forces(ds_train, lp)
e_test_pred, f_test_pred = get_all_energies(ds_test, lp), get_all_forces(ds_test, lp)
@savevar path e_train
@savevar path e_train_pred
@savevar path f_train
@savevar path f_train_pred
@savevar path e_test
@savevar path e_test_pred
@savevar path f_test
@savevar path f_test_pred

# Compute metrics
metrics = get_metrics( e_train_pred, e_train, f_train_pred, f_train,
                       e_test_pred, e_test, f_test_pred, f_test,
                       B_time, dB_time, learn_time)
@savecsv path metrics

# Plot and save results
e_test_plot = plot_energy(e_test_pred, e_test)
@savefig path e_test_plot
f_test_plot = plot_forces(f_test_pred, f_test)
@savefig path f_test_plot
f_test_cos = plot_cos(f_test_pred, f_test)
@savefig path f_test_cos

