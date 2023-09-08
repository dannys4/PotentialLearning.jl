using Flux
using Optim


# Neural network interatomic potential
mutable struct NNIAP
    nn
    iap
end

# Neural network potential formulation using local descriptors to compute energy and forces
# See 10.1103/PhysRevLett.98.146401
#     https://fitsnap.github.io/Pytorch.html

function potential_energy(c::Configuration, nniap::NNIAP)
    Bs = get_values(get_local_descriptors(c))
    s = sum(sum([nniap.nn(B_atom) for B_atom in Bs]))
    return s
end

function force(c::Configuration, nniap::NNIAP)
    Bs = get_values(get_local_descriptors(c))
    dnndb = [first(gradient(x->sum(nniap.nn(x)), B_atom)) for B_atom in Bs]
    dbdr = get_values(get_force_descriptors(c))
    return [[-sum(dnndb .⋅ [dbdr[atom][coor]]) for coor in 1:3] for atom in 1:length(dbdr)]
end

# Neural network potential formulation using global descriptors to compute energy and forces
# See https://docs.google.com/presentation/d/1XI9zqF_nmSlHgDeFJqq2dxdVqiiWa4Z-WJKvj0TctEk/edit#slide=id.g169df3c161f_63_123

#function potential_energy(c::Configuration, nniap::NNIAP)
#    Bs = sum(get_values(get_local_descriptors(c)))
#    return sum(nniap.nn(Bs))
#end

#function force(c::Configuration, nniap::NNIAP)
#    B = sum(get_values(get_local_descriptors(c)))
#    dnndb = first(gradient(x->sum(nniap.nn(x)), B)) 
#    dbdr = get_values(get_force_descriptors(c))
#    return [[-dnndb ⋅ dbdr[atom][coor] for coor in 1:3]
#             for atom in 1:length(dbdr)]
#end


# Loss function ################################################################
function loss(nn, iap, ds, w_e=1, w_f=1)
    nniap = NNIAP(nn, iap)
    es, es_pred = get_all_energies(ds), get_all_energies(ds, nniap)
    fs, fs_pred = get_all_forces(ds), get_all_forces(ds, nniap)
    return w_e * Flux.mse(es_pred, es) + w_f * Flux.mse(fs_pred, fs)
end

function loss(nn, iap, atom_config_list, true_energy, local_descriptors, w_e=1, w_f=1)
    nn_local_descriptors = nn(local_descriptors)
    atom_descriptors_list = [nn_local_descriptors[:, atom_config_list[i]+1:atom_config_list[i+1]] for i in 1:length(atom_config_list)-1]
    atom_sum_pred = sum.(atom_descriptors_list)
    return w_e * Flux.mse(atom_sum_pred, true_energy)
end


# Auxiliary functions ##########################################################


function PotentialLearning.get_all_energies(ds::DataSet, nniap::NNIAP)
    return [potential_energy(ds[c], nniap) for c in 1:length(ds)]
end


function PotentialLearning.get_all_forces(ds::DataSet, nniap::NNIAP)
    return reduce(vcat,reduce(vcat,[force(ds[c], nniap) for c in 1:length(ds)]))
end

function batch_and_shuffle(data, num_batches)
    # Shuffle the data
    shuffle!(data)

    # Calculate the number of batches
    batch_size = ceil(Int, length(data) / num_batches)
    # Create the batches
    batches = [data[(i-1)*batch_size+1:min(i*batch_size, end)] for i in 1:num_batches]

    return batches
end

# NNIAP learning functions #####################################################

# Flux.jl training
function learn!(nniap, ds, opt::Flux.Optimise.AbstractOptimiser, epochs, loss, w_e, w_f)
    optim = Flux.setup(opt, nniap.nn)  # will store optimiser momentum, etc.
    ∇loss(nn, iap, ds, w_e, w_f) = gradient((nn) -> loss(nn, iap, ds, w_e, w_f), nn)
    losses = []
    for epoch in 1:epochs
        # Compute gradient with current parameters and update model
        grads = ∇loss(nniap.nn, nniap.iap, ds, w_e, w_f)
        Flux.update!(optim, nniap.nn, grads[1])
        # Logging
        curr_loss = loss(nniap.nn, nniap.iap, ds, w_e, w_f)
        push!(losses, curr_loss)
        println(curr_loss)
    end
end

function learn!(nace, ds_train, opt, n_epochs, n_batches, loss, w_e, w_f, _device)
    nn = nace.nn |> _device
    optim = Flux.setup(opt, nn) |> _device
    ∇loss(nn, iap, atom_config_list, true_energy, local_descriptors, w_e, w_f) = gradient((nn) -> loss(nn, iap, atom_config_list,  true_energy, local_descriptors, w_e, w_f), nn)
    losses = []
    batch_lists = batch_and_shuffle(collect(1:length(ds_train)), n_batches)
    batch_list_len = length(batch_lists)
    
    for epoch in 1:n_epochs
        batch_index = mod(epoch, batch_list_len) + 1 
        ds_batch = ds_train[batch_lists[batch_index]]

        true_energy = Float32.(get_all_energies(ds_batch))
        
        local_descriptors = get_values.(get_local_descriptors.(ds_batch))
        local_descriptors = reduce(hcat, reduce(hcat, local_descriptors)) |> _device

        atom_config_list = vcat([0], cumsum(length.(get_system.(ds_batch))))

        # Compute gradient with current parameters and update model
        grads = ∇loss(nn, nace.iap, atom_config_list, true_energy, local_descriptors, w_e, w_f)
        Flux.update!(optim, nn, grads[1])

        # Logging
        if epoch % 100 == 0
            curr_loss = loss(nn, nace.iap, atom_config_list, true_energy, local_descriptors, w_e, w_f)
            push!(losses, curr_loss)
            println("Epoch: $epoch, loss: $curr_loss")
        end
        
    end
    nace.nn = nn |> cpu
end


# Optimization.jl training
function learn!(nniap, ds, opt::Optim.FirstOrderOptimizer, maxiters, loss, w_e, w_f)
    ps, re = Flux.destructure(nniap.nn)
    batchloss(ps, p) = loss(re(ps), nniap.iap, ds, w_e, w_f)
    ∇bacthloss = OptimizationFunction(batchloss, Optimization.AutoForwardDiff()) # Optimization.AutoZygote()
    prob = OptimizationProblem(∇bacthloss, ps, []) # prob = remake(prob,u0=sol.minimizer)
    cb = function (p, l) println("Loss BFGS: $l"); return false end
    sol = solve(prob, opt, maxiters=maxiters, callback = cb)
    ps = sol.u
    nn = re(ps)
    nniap.nn = nn
    #copyto!(nniap.nn, nn)
    #global nniap = NNIAP(nn, nniap.iap) # TODO: improve this
end