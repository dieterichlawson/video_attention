require 'torch'
require 'nn'
require 'optim'

require 'AttentionCaptioningModel'
require 'util.DataLoader'

local utils = require 'util.utils'
local unpack = unpack or table.unpack

local cmd = torch.CmdLine()

-- Dataset options
cmd:option('-input_h5', '/data/coco/coco_bgr_noavg.h5')
cmd:option('-input_json', '/data/coco/coco_vocab.json')
cmd:option('-batch_size', 50)

-- Model options
cmd:option('-model_type', 'lstm')
cmd:option('-wordvec_size', 64)
cmd:option('-rnn_size', 128)
cmd:option('-num_layers', 2)
cmd:option('-dropout', 0)
cmd:option('-batchnorm', 0)

-- Optimization options
cmd:option('-max_epochs', 50)
cmd:option('-learning_rate', 2e-3)
cmd:option('-grad_clip', 5)
cmd:option('-lr_decay_every', 1)
cmd:option('-lr_decay_factor', 0.5)

-- Output options
cmd:option('-print_every', 1)
cmd:option('-checkpoint_every', 1000)
cmd:option('-checkpoint_name', '/data/checkpoints/checkpoint')

-- Benchmark options
cmd:option('-speed_benchmark', 0)
cmd:option('-memory_benchmark', 0)

-- Backend options
cmd:option('-gpu', 0)
cmd:option('-gpu_backend', 'cuda')

local opt = cmd:parse(arg)


-- Set up GPU stuff
local dtype = 'torch.FloatTensor'
if opt.gpu >= 0 and opt.gpu_backend == 'cuda' then
  require 'cutorch'
  require 'cunn'
  cutorch.setDevice(opt.gpu + 1)
  dtype = 'torch.CudaTensor'
  print(string.format('Running with CUDA on GPU %d', opt.gpu))
elseif opt.gpu >= 0 and opt.gpu_backend == 'opencl' then
  -- Memory benchmarking is only supported in CUDA mode
  -- TODO: Time benchmarking is probably wrong in OpenCL mode.
  require 'cltorch'
  require 'clnn'
  cltorch.setDevice(opt.gpu + 1)
  dtype = torch.Tensor():cl():type()
  print(string.format('Running with OpenCL on GPU %d', opt.gpu))
else
  -- Memory benchmarking is only supported in CUDA mode
  opt.memory_benchmark = 0
  print 'Running in CPU mode'
end


-- Initialize the DataLoader and vocabulary
local loader = DataLoader(opt)
local vocab = utils.read_json(opt.input_json)
local idx_to_token = {}
for k, v in pairs(vocab.idx_to_token) do
  -- NOTE that lua is 1- indexed while python is 0-indexed
  -- so we add one to translate
  idx_to_token[tonumber(k)+1] = v
end

-- Get the dimensions from the DataLoader
local opt_clone = torch.deserialize(torch.serialize(opt))
local N, truth_capt_len = loader.batch_size, loader.capt_len
local seq_length = truth_capt_len - 1
opt_clone.idx_to_token = idx_to_token
opt_clone.im_size = loader.image_size
print(string.format('Detected image size %dx%dx%d', opt_clone.im_size[1], 
    opt_clone.im_size[2], opt_clone.im_size[3]))

-- Initialize the model and criterion
local model = nn.AttentionCaptioningModel(opt_clone):type(dtype)
local params, grad_params = model:getParameters()
local crit = nn.CrossEntropyCriterion():type(dtype)

-- Set up some variables we will use below
local train_loss_history = {}
local val_loss_history = {}
local val_loss_history_it = {}
local forward_backward_times = {}
local init_memory_usage, memory_usage = nil, {}

if opt.memory_benchmark == 1 then
  -- This should only be enabled in GPU mode
  assert(cutorch)
  cutorch.synchronize()
  local free, total = cutorch.getMemoryUsage(cutorch.getDevice())
  init_memory_usage = total - free
end

-- Loss function that we pass to an optim method
local function f(w)
  assert(w == params)
  grad_params:zero()

  -- Get a minibatch and run the model forward, maybe timing it
  local timer
  local feats, capts = loader:nextBatch('train')
  assert(opt.rnn_size == feats:size()[2])
  -- load features and raw caption 
  feats, capts = feats:type(dtype), capts:type(dtype)
  capts:add(1)
  
  if opt.speed_benchmark == 1 then
    if cutorch then cutorch.synchronize() end
    timer = torch.Timer()
  end

  X = capts[{{},{1,-2}}]:clone()
  y = capts[{{},{2,-1}}]:clone()
  assert(X:size(2)==seq_length,"Sequence length doesn't match the supplied captions")
  assert(y:size(2)==seq_length,"Sequence length doesn't match the supplied captions")
  model:resetStates()
  local scores = model:forward({feats,X})

  -- Use the Criterion to compute loss; we need to reshape the scores to be
  -- two-dimensional before doing so. Annoying.
  local scores_view = scores:view(N * seq_length, -1)
  local y_view = y:view(N * seq_length)
  local loss = crit:forward(scores_view, y_view)

  -- Run the Criterion and model backward to compute gradients, maybe timing it
  local grad_scores = crit:backward(scores_view, y_view):view(N, seq_length, -1)
  model:backward(X, grad_scores,nil)
  if timer then
    if cutorch then cutorch.synchronize() end
    local time = timer:time().real
    print('Forward / Backward pass took ', time)
    table.insert(forward_backward_times, time)
  end

  -- Maybe record memory usage
  if opt.memory_benchmark == 1 then
    assert(cutorch)
    if cutorch then cutorch.synchronize() end
    local free, total = cutorch.getMemoryUsage(cutorch.getDevice())
    local memory_used = total - free - init_memory_usage
    local memory_used_mb = memory_used / 1024 / 1024
    print(string.format('Using %dMB of memory', memory_used_mb))
    table.insert(memory_usage, memory_used)
  end

  if opt.grad_clip > 0 then
    grad_params:clamp(-opt.grad_clip, opt.grad_clip)
  end

  return loss, grad_params
end

-- Train the model!
local optim_config = {learningRate = opt.learning_rate}
local num_train = loader.split_sizes['train']
local num_iterations = opt.max_epochs * num_train
model:training()
for i = 1, num_iterations do
  local epoch = math.floor(i / num_train) + 1

  if i % opt.lr_decay_every == 0 then
    local old_lr = optim_config.learningRate
    optim_config = {learningRate = old_lr * opt.lr_decay_factor}
  end

  -- Take a gradient step and maybe print
  -- Note that adam returns a singleton array of losses
  local _, loss = optim.adam(f, params, optim_config)
  table.insert(train_loss_history, loss[1])
  if opt.print_every > 0 and i % opt.print_every == 0 then
    local float_epoch = i / num_train + 1
    local msg = 'Epoch %.2f / %d, i = %d / %d, lr= %f, loss = %f'
    local args = {msg, float_epoch, opt.max_epochs, i, num_iterations, optim_config.learningRate, loss[1]}
    print(string.format(unpack(args)))
  end

  -- Maybe save a checkpoint
  local check_every = opt.checkpoint_every
  if (check_every > 0 and i % check_every == 0) or i == num_iterations then
    -- First save a JSON checkpoint, excluding the model
    local checkpoint = {
      opt = opt,
      train_loss_history = train_loss_history,
      --val_loss_history = val_loss_history,
      --val_loss_history_it = val_loss_history_it,
      forward_backward_times = forward_backward_times,
      memory_usage = memory_usage,
    }
    local filename = string.format('%s_%d.json', opt.checkpoint_name, i)
    -- Make sure the output directory exists before we try to write it
    paths.mkdir(paths.dirname(filename))
    utils.write_json(filename, checkpoint)

    -- Now save a torch checkpoint with the model
    model:clearState()
    --model:float()
    checkpoint.model = model

    local filename = string.format('%s_%d.t7', opt.checkpoint_name, i)
    paths.mkdir(paths.dirname(filename))
    torch.save(filename, checkpoint)
    --model:type(dtype)
    params, grad_params = model:getParameters()
    collectgarbage()
  end
end
