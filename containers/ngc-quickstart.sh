#!/usr/bin/env bash
cat << 'GUIDE'

================================================================================
  NGC PyTorch Environment — Quick Start Guide
================================================================================

  Workspace: /workspace (mounted from host ~/)
  Type 'quickstart' at any time to show this guide again.

--------------------------------------------------------------------------------
  VERIFY GPU
--------------------------------------------------------------------------------
  python -c "import torch; print(torch.cuda.get_device_name(0))"

================================================================================
  PRE-INSTALLED PACKAGES
================================================================================

  TORCH (PyTorch) — Deep learning framework
  ──────────────────────────────────────────
  Core tensor computation and neural network library with CUDA acceleration.

    python -c "import torch; x = torch.randn(3,3).cuda(); print(x)"

  TRANSFORMERS — Model hub & inference
  ──────────────────────────────────────────
  Load and run thousands of pre-trained models from HuggingFace.

    from transformers import pipeline
    pipe = pipeline("text-generation", model="meta-llama/Llama-3.1-8B-Instruct", device="cuda")
    print(pipe("Explain quantum computing in one sentence"))

  PEFT — Parameter-Efficient Fine-Tuning
  ──────────────────────────────────────────
  Add LoRA/QLoRA adapters to large models for lightweight fine-tuning.

    from peft import LoraConfig, get_peft_model
    config = LoraConfig(r=16, lora_alpha=32, target_modules=["q_proj", "v_proj"])
    model = get_peft_model(base_model, config)

  TRL — Transformer Reinforcement Learning
  ──────────────────────────────────────────
  SFT, RLHF, and DPO training pipelines for LLMs.

    from trl import SFTTrainer, SFTConfig
    trainer = SFTTrainer(model=model, train_dataset=dataset, args=SFTConfig(output_dir="./out"))
    trainer.train()

  BITSANDBYTES — Quantization
  ──────────────────────────────────────────
  4-bit and 8-bit quantization for reduced memory usage.

    from transformers import BitsAndBytesConfig
    bnb_config = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype=torch.float16)
    model = AutoModelForCausalLM.from_pretrained("meta-llama/...", quantization_config=bnb_config)

  UNSLOTH — Fast Fine-Tuning
  ──────────────────────────────────────────
  2-5x faster LoRA fine-tuning with 70% less memory.

    from unsloth import FastLanguageModel
    model, tokenizer = FastLanguageModel.from_pretrained("meta-llama/Llama-3.1-8B", load_in_4bit=True)
    model = FastLanguageModel.get_peft_model(model, r=16, target_modules=["q_proj","v_proj"])

  DIFFUSERS — Image Generation
  ──────────────────────────────────────────
  Stable Diffusion, Flux, and other image generation models.

    from diffusers import StableDiffusionPipeline
    pipe = StableDiffusionPipeline.from_pretrained("stabilityai/stable-diffusion-2-1").to("cuda")
    image = pipe("a photo of an astronaut riding a horse").images[0]
    image.save("output.png")

  DATASETS — Data Loading
  ──────────────────────────────────────────
  Load and process datasets from HuggingFace Hub or local files.

    from datasets import load_dataset
    ds = load_dataset("imdb")
    ds = load_dataset("json", data_files="my_data.jsonl")

  ACCELERATE — Multi-GPU & Mixed Precision
  ──────────────────────────────────────────
  Distributed training and mixed precision with minimal code changes.

    accelerate launch --mixed_precision fp16 train.py
    accelerate config  # interactive setup

  TENSORRT — Optimized Inference
  ──────────────────────────────────────────
  NVIDIA's inference optimizer, pre-installed in this container.

    import torch_tensorrt
    optimized = torch_tensorrt.compile(model, inputs=[torch_tensorrt.Input((1, 3, 224, 224))])

================================================================================
  COMMON WORKFLOWS
================================================================================

  Full fine-tune with Unsloth + TRL:
    1. Load model:    model, tok = FastLanguageModel.from_pretrained(...)
    2. Add LoRA:      model = FastLanguageModel.get_peft_model(model, r=16)
    3. Train:         SFTTrainer(model=model, dataset=ds, ...).train()
    4. Save:          model.save_pretrained("./my-adapter")
    5. Merge & push:  model.push_to_hub("username/my-model")

  Serve a model (inside container):
    python -m transformers.serve --model meta-llama/Llama-3.1-8B-Instruct --port 8001

================================================================================
GUIDE
