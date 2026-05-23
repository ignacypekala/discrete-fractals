vim.api.nvim_create_autocmd("FileType", {
    pattern = "asm",
    callback = function()
        vim.opt_local.makeprg = "make"
        vim.opt_local.colorcolumn = "100"
        vim.opt_local.expandtab = true
        vim.opt_local.varsofttabstop = "8,8,24,8"
        vim.opt_local.shiftwidth = 0
        vim.opt_local.indentexpr = ""
    end,
    group = vim.api.nvim_create_augroup("ProjectNasmConfig", { clear = true })
})

