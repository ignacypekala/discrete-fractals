vim.api.nvim_create_autocmd("FileType", {
    pattern = "asm",
    callback = function()
        print("hello")
        vim.opt_local.expandtab = true
        vim.opt_local.varsofttabstop = "8,32,8"
        vim.opt_local.shiftwidth = 0
        vim.opt_local.indentexpr = ""
    end,
    group = vim.api.nvim_create_augroup("ProjectNasmConfig", { clear = true })
})
