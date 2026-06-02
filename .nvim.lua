vim.api.nvim_create_autocmd("FileType", {
    pattern = "asm",
    callback = function()
        vim.opt_local.makeprg = "make"
        vim.opt_local.textwidth = 100
        vim.opt_local.colorcolumn = "+1"
        vim.opt_local.expandtab = true
        -- Layout:
        -- mnemonics: col 5
        -- operands: 25
        -- comments 57
        vim.opt_local.tabstop = 4
        vim.opt_local.varsofttabstop = "24,32,8"
        vim.opt_local.shiftwidth = 0
        vim.opt_local.indentexpr = ""
    end,
    group = vim.api.nvim_create_augroup("ProjectNasmConfig", { clear = true })
})

