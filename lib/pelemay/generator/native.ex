defmodule Pelemay.Generator.Native do
  alias Pelemay.Db
  alias Pelemay.Generator

  def generate(module) do
    Generator.libc(module) |> write(module)
  end

  defp write(file, module) do
    str =
      init_nif()
      |> basic()
      |> generate_functions()
      |> erl_nif_init(module)

    file |> File.write(str)
  end

  defp generate_functions(str) do
    definition_func =
      Db.get_functions()
      |> Enum.map(&(&1 |> generate_function))
      |> to_str_code

    str <> definition_func <> func_list()
  end

  defp generate_function([func_info]) do
    enum_map_SIMD(func_info)
  end

  defp to_str_code(list) when list |> is_list do
    list
    |> Enum.reduce(
      "",
      fn x, acc -> acc <> to_string(x) end
    )
  end

  defp func_list do
    fl =
      Db.get_functions()
      |> Enum.reduce(
        "",
        fn x, acc ->
          str = x |> erl_nif_func
          acc <> "#{str},"
        end
      )

    """
    static
    ErlNifFunc nif_funcs[] =
    {
      // {erl_function_name, erl_function_arity, c_function}
      #{fl}
    };
    """
  end

  defp erl_nif_func([%{nif_name: nif_name, arg_num: num}]) do
    ~s/{"#{nif_name}", #{num}, #{nif_name}}/
  end

  defp init_nif do
    """
    // This file was generated by Pelemay.Generator.Native
    #include<stdbool.h>
    #include<erl_nif.h>
    #include<string.h>

    ERL_NIF_TERM atom_struct;
    ERL_NIF_TERM atom_range;
    ERL_NIF_TERM atom_first;
    ERL_NIF_TERM atom_last;

    static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info);
    static void unload(ErlNifEnv *env, void *priv);
    static int reload(ErlNifEnv *env, void **priv, ERL_NIF_TERM info);
    static int upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info);

    static int
    load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
    {
      atom_struct = enif_make_atom(env, "__struct__");
      atom_range = enif_make_atom(env, "Elixir.Range");
      atom_first = enif_make_atom(env, "first");
      atom_last = enif_make_atom(env, "last");
      return 0;
    }

    static void
    unload(ErlNifEnv *env, void *priv)
    {
    }

    static int
    reload(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
    {
      return 0;
    }

    static int
    upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
    {
      return load(env, priv, info);
    }
    """
  end

  defp erl_nif_init(str, module) do
    str <>
      """
      ERL_NIF_INIT(Elixir.#{Generator.nif_module(module)}, nif_funcs, &load, &reload, &upgrade, &unload)
      """
  end

  defp basic(str) do
    {:ok, ret} = File.read(__DIR__ <> "/native/basic.c")

    str <> ret
  end

  # defp arithmetic(str) do
  #   str <> File.read(@dir <> "arithmetic.c")
  # end

  defp enclosure(str) do
    "(#{str})"
  end

  defp make_expr(operators, args, type)
       when is_list(operators) and is_list(args) do
    args = args |> to_string(:args, type)

    operators = operators |> to_string(:op)

    last_arg = List.last(args)

    expr =
      Enum.zip(args, operators)
      |> Enum.reduce("", &make_expr/2)

    if type == "double" && String.contains?(expr, "%") do
      "(vec_double[i])"
    else
      enclosure(expr <> last_arg)
    end
  end

  defp make_expr({arg, operator}, acc) do
    enclosure(acc <> arg) <> operator
  end

  defp to_string(args, :args, "double") do
    args
    |> Enum.map(&(&1 |> arg_to_string("double")))
  end

  defp to_string(args, :args, type) do
    args
    |> Enum.map(&(&1 |> arg_to_string(type)))
  end

  defp to_string(operators, :op) do
    operators
    |> Enum.map(&(&1 |> operator_to_string))
  end

  defp arg_to_string(arg, type) do
    case arg do
      {:&, _meta, [1]} -> "vec_#{type}[i]"
      {_, _, nil} -> "vec_#{type}[i]"
      other -> "#{other}"
    end
  end

  defp operator_to_string(operator) do
    case operator do
      :rem -> "%"
      other -> other |> to_string
    end
  end

  # defp enum_map_SIMD_(str, operator, num)
  defp enum_map_SIMD(%{nif_name: nif_name, args: args, operators: operators}) do
    expr_d = make_expr(operators, args, "double")
    expr_l = make_expr(operators, args, "long")

    # expr_d = case operators do
    #   :% -> ""
    #   _ -> "#{str_operator}  #{args}"
    # end

    # expr_l = "#{str_operator} (long)#{args}"

    """
    static ERL_NIF_TERM
    #{nif_name}(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
    {
      if (__builtin_expect((argc != 1), false)) {
        return enif_make_badarg(env);
      }
      ErlNifSInt64 *vec_long;
      size_t vec_l;
      double *vec_double;
      if (__builtin_expect((enif_get_int64_vec_from_list(env, argv[0], &vec_long, &vec_l) == fail), false)) {
        if (__builtin_expect((enif_get_double_vec_from_list(env, argv[0], &vec_double, &vec_l) == fail), false)) {
          return enif_make_badarg(env);
        }
    #pragma clang loop vectorize_width(loop_vectorize_width)
        for(size_t i = 0; i < vec_l; i++) {
          vec_double[i] = #{expr_d};
        }
        return enif_make_list_from_double_vec(env, vec_double, vec_l);
      }
    #pragma clang loop vectorize_width(loop_vectorize_width)
      for(size_t i = 0; i < vec_l; i++) {
        vec_long[i] = #{expr_l};
      }
      return enif_make_list_from_int64_vec(env, vec_long, vec_l);
    }
    """
  end

  # defp enum_map_CUDA_(str, operator, num)
  defp enum_map_CUDA(%{nif_name: nif_name, args: args, operators: operators}) do
    expr_d = make_expr(operators, args, "double")
    expr_l = make_expr(operators, args, "long")

    # expr_d = case operators do
    #   :% -> ""
    #   _ -> "#{str_operator}  #{args}"
    # end

    # expr_l = "#{str_operator} (long)#{args}"

    """
    __global__ void enum_map_double_kernel(const size_t vec_l, double* vec_double)
    {
      int i = blockIdx.x * blockDim.x + threadIdx.x;
      if(i < vec_l){
        vec_double[i] = #{expr_d};
      }
    }

    __global__ void enum_map_long_kernel(const size_t vec_l, long* vec_long)
    {
      int i = blockIdx.x * blockDim.x + threadIdx.x;
      if(i < vec_l){
        vec_long[i] = #{expr_l};
      }
    }

    void enum_map_double_host(const size_t vec_l, double* vec_double)
    {
      double* dev_vec_double;
      if (__builtin_expect((cudaMalloc(&dev_vec_double, vec_l * sizeof(vec_double[0])) != cudaSuccess), false)) {
        // the occured error may be cudaErrorInvalidValue or cudaErrorMemoryAllocation.
        return enif_make_badarg(env);
      }
      if (__builtin_expect((cudaMemcpy(dev_vec_double, vec_double, vec_l * sizeof(vec_double[0]), cudaMemcpyHostToDevice) != cudaSuccess), false)) {
        // the occured error may be cudaErrorInvalidValue or cudaErrorInvalidMemcpyDirection.
        return enif_make_badarg(env);
      }
  
      enum_map_double_kernel <<< (vec_l + 255)/256, 256 >>> (vec_l, vec_double);
  
      if (__builtin_expect((cudaMemcpy(vec_double, dev_vec_double, vec_l * sizeof(vec_double[0]), cudaMemcpyDeviceToHost) != cudaSuccess), false)) {
        // the occured error may be cudaErrorInvalidValue or cudaErrorInvalidMemcpyDirection.
        return enif_make_badarg(env);
      }
      if (__builtin_expect((cudaFree(dev_vec_double) != cudaSuccess), false)) {
        // the occured error may be cudaErrorInvalidValue.
        return enif_make_badarg(env);
      }
    }

    void enum_map_long_host(const size_t vec_l, long* vec_long)
    {
      long* dev_vec_long;
      if (__builtin_expect((cudaMalloc(&dev_vec_long, vec_l * sizeof(vec_long[0])) != cudaSuccess), false)) {
        // the occured error may be cudaErrorInvalidValue or cudaErrorMemoryAllocation.
        return enif_make_badarg(env);
      }      
      if (__builtin_expect((cudaMemcpy(dev_vec_long, vec_long, vec_l * sizeof(vec_long[0]), cudaMemcpyHostToDevice) != cudaSuccess), false)) {
        // the occured error may be  cudaErrorInvalidValue or cudaErrorInvalidMemcpyDirection.
        return enif_make_badarg(env);
      }
  
      enum_map_long_kernel <<< (vec_l + 255)/256, 256 >>> (vec_l, vec_long);
  
      if (__builtin_expect((cudaMemcpy(vec_long, dev_vec_long, vec_l * sizeof(vec_long[0]), cudaMemcpyDeviceToHost) != cudaSuccess), false)) {
        // the occured error may be  cudaErrorInvalidValue or cudaErrorInvalidMemcpyDirection.
        return enif_make_badarg(env);
      }
      if (__builtin_expect((cudaFree(dev_vec_long) != cudaSuccess), false)) {
        // the occured error may be cudaErrorInvalidValue.
        return enif_make_badarg(env);
      }
    }

    static ERL_NIF_TERM
    #{nif_name}(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
    {
      if (__builtin_expect((argc != 1), false)) {
        return enif_make_badarg(env);
      }
      ErlNifSInt64 *vec_long;
      size_t vec_l;
      double *vec_double;
      if (__builtin_expect((enif_get_int64_vec_from_list(env, argv[0], &vec_long, &vec_l) == fail), false)) {
        if (__builtin_expect((enif_get_double_vec_from_list(env, argv[0], &vec_double, &vec_l) == fail), false)) {
          return enif_make_badarg(env);
        }
        enum_map_double_host(vec_l, vec_double);
        return enif_make_list_from_double_vec(env, vec_double, vec_l);
      }
      enum_map_long_host(vec_l, vec_long);
      return enif_make_list_from_int64_vec(env, vec_long, vec_l);
    }
    """
  end

  # defp chunk_every(str) do
  #   str <> File.read(@dir <> "enum.c")
  # end
end
